//
//  SQLiteCreateTableDDL.swift
//  SQLiteDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting

// The id `SQLitePlugin.databaseTypeId` holds, for the files iOS compiles without the plugin class.
nonisolated internal let sqliteDatabaseTypeId = "SQLite"

// Free functions, so the test target exercises the DDL without a connection.
nonisolated internal func sqliteQuoteIdentifier(_ name: String) -> String {
    SQLQuoting.identifier(name, quote: .backtick)
}

// SQLite reads statement text only up to a NUL, so a NUL in a value goes in as char(0) between two literals.
nonisolated internal func sqliteStringLiteralBody(_ value: String) -> String {
    value.split(separator: "\0", omittingEmptySubsequences: false)
        .map { SQLQuoting.stringLiteralBody(String($0)) }
        .joined(separator: "'||char(0)||'")
}

// Type, default and generation text, from the catalog or the user, goes into DDL only as one type or expression.
nonisolated internal func sqliteColumnRefusal(
    name: String,
    type: String?,
    defaultValue: String?,
    generationExpression: String? = nil
) -> String? {
    let typeId = sqliteDatabaseTypeId
    if let type, !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       !SQLExpressionFragment.isSingleType(type, databaseTypeId: typeId) {
        return String(format: String(localized: "The type of column %@ cannot be written as SQL."), name)
    }
    if let defaultValue, !defaultValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       !SQLExpressionFragment.isSingleExpression(defaultValue, databaseTypeId: typeId) {
        return String(format: String(localized: "The default of column %@ cannot be written as SQL."), name)
    }
    if let generationExpression = generationExpression?.nilIfEmpty,
       !SQLExpressionFragment.isSingleExpression(generationExpression, databaseTypeId: typeId) {
        return String(format: String(localized: "The expression of generated column %@ cannot be written as SQL."), name)
    }
    return nil
}

nonisolated internal func sqliteColumnRefusal(_ column: PluginColumnDefinition) -> String? {
    sqliteColumnRefusal(
        name: column.name,
        type: column.dataType,
        defaultValue: column.defaultValue,
        generationExpression: column.generationExpression
    )
}

nonisolated internal func sqliteRespecificationRefusal(_ respecification: PluginTableRespecification) -> String? {
    respecification.addedColumns.lazy.compactMap { sqliteColumnRefusal($0) }.first
        ?? respecification.alteredColumns.lazy.compactMap {
            sqliteColumnRefusal(name: $0.column, type: $0.type, defaultValue: $0.defaultValue)
        }.first
}

// The partial-index predicate and the key list come back from `sqlite_master` and are spliced as written.
nonisolated internal func sqliteIndexRefusal(_ index: PluginIndexDefinition) -> String? {
    let typeId = sqliteDatabaseTypeId
    let keys = index.ddlMethodAndKeys?.nilIfEmpty.map { [$0] } ?? (index.expressions ?? [])
    guard keys.allSatisfy({ SQLExpressionFragment.isSingleExpression($0, databaseTypeId: typeId) }) else {
        return String(format: String(localized: "Index %@ has a key part that is not one SQL expression."), index.name)
    }
    if let predicate = index.whereClause?.nilIfEmpty, !SQLExpressionFragment.isSingleExpression(predicate, databaseTypeId: typeId) {
        return String(format: String(localized: "The condition of index %@ cannot be written as SQL."), index.name)
    }
    return nil
}

nonisolated internal func sqliteCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
    guard !definition.columns.isEmpty, definition.columns.allSatisfy({ sqliteColumnRefusal($0) == nil }) else { return nil }

    let declaredKey = Set(definition.primaryKeyColumns)
    let keyColumns = definition.columns.filter { $0.isPrimaryKey || declaredKey.contains($0.name) }
    let inlineKeyColumn = keyColumns.count == 1 ? keyColumns.first?.name : nil

    var parts = definition.columns.map {
        sqliteColumnDefinitionSQL($0, isInlinePrimaryKey: $0.name == inlineKeyColumn)
    }

    if keyColumns.count > 1 {
        let names = keyColumns.map { sqliteQuoteIdentifier($0.name) }.joined(separator: ", ")
        parts.append("PRIMARY KEY (\(names))")
    }

    parts.append(contentsOf: definition.foreignKeys.map(sqliteForeignKeyDefinitionSQL))

    let ifNotExists = definition.ifNotExists ? "IF NOT EXISTS " : ""
    return "CREATE TABLE \(ifNotExists)\(sqliteQuoteIdentifier(definition.tableName)) (\n  "
        + parts.joined(separator: ",\n  ")
        + "\n);"
}

// Only the inline key arm writes `AUTOINCREMENT`, so a key named by `primaryKeyColumns` alone is declared here too.
nonisolated internal func sqliteColumnDefinitionSQL(
    _ column: PluginColumnDefinition,
    isInlinePrimaryKey: Bool
) -> String {
    var definition = "\(sqliteQuoteIdentifier(column.name)) \(column.dataType)"
    if let expression = column.generationExpression?.nilIfEmpty {
        definition += " GENERATED ALWAYS AS (\(expression)) \((column.generationKind ?? .virtual).rawValue)"
        if !column.isNullable { definition += " NOT NULL" }
        return definition
    }
    if isInlinePrimaryKey {
        definition += " PRIMARY KEY"
        if column.autoIncrement {
            definition += " AUTOINCREMENT"
        }
    }
    if !column.isNullable {
        definition += " NOT NULL"
    }
    if let defaultValue = column.defaultValue {
        definition += " DEFAULT \(defaultValue)"
    }
    return definition
}

// `REFERENCES "t" ()` is a syntax error and bare `REFERENCES "t"` means the parent's key; SQLite has no cross-schema key.
nonisolated internal func sqliteForeignKeyDefinitionSQL(_ foreignKey: PluginForeignKeyDefinition) -> String {
    let columns = foreignKey.columns.map(sqliteQuoteIdentifier).joined(separator: ", ")
    let constraint = foreignKey.name.isEmpty
        ? ""
        : "CONSTRAINT \(sqliteQuoteIdentifier(foreignKey.name)) "
    var definition = "\(constraint)FOREIGN KEY (\(columns)) "
        + "REFERENCES \(sqliteQuoteIdentifier(foreignKey.referencedTable))"
    if !foreignKey.referencedColumns.isEmpty {
        definition += " (\(foreignKey.referencedColumns.map(sqliteQuoteIdentifier).joined(separator: ", ")))"
    }
    if foreignKey.onDelete != "NO ACTION" {
        definition += " ON DELETE \(foreignKey.onDelete)"
    }
    if foreignKey.onUpdate != "NO ACTION" {
        definition += " ON UPDATE \(foreignKey.onUpdate)"
    }
    return definition
}
