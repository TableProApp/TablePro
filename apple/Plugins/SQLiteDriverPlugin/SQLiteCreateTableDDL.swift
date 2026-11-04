//
//  SQLiteCreateTableDDL.swift
//  SQLiteDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting

// Free functions, so the test target exercises the DDL without a connection.
internal func sqliteQuoteIdentifier(_ name: String) -> String {
    SQLQuoting.identifier(name, quote: .backtick)
}

// Type, default and generation text, from the catalog or the user, goes into DDL only as one type or expression.
internal func sqliteColumnRefusal(
    name: String,
    type: String?,
    defaultValue: String?,
    generationExpression: String? = nil
) -> String? {
    let typeId = SQLitePlugin.databaseTypeId
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

internal func sqliteColumnRefusal(_ column: PluginColumnDefinition) -> String? {
    sqliteColumnRefusal(
        name: column.name,
        type: column.dataType,
        defaultValue: column.defaultValue,
        generationExpression: column.generationExpression
    )
}

internal func sqliteRespecificationRefusal(_ respecification: PluginTableRespecification) -> String? {
    respecification.addedColumns.lazy.compactMap { sqliteColumnRefusal($0) }.first
        ?? respecification.alteredColumns.lazy.compactMap {
            sqliteColumnRefusal(name: $0.column, type: $0.type, defaultValue: $0.defaultValue)
        }.first
}

// The partial-index predicate and the key list come back from `sqlite_master` and are spliced as written.
internal func sqliteIndexRefusal(_ index: PluginIndexDefinition) -> String? {
    let typeId = SQLitePlugin.databaseTypeId
    let keys = index.ddlMethodAndKeys?.nilIfEmpty.map { [$0] } ?? (index.expressions ?? [])
    guard keys.allSatisfy({ SQLExpressionFragment.isSingleExpression($0, databaseTypeId: typeId) }) else {
        return String(format: String(localized: "Index %@ has a key part that is not one SQL expression."), index.name)
    }
    if let predicate = index.whereClause?.nilIfEmpty, !SQLExpressionFragment.isSingleExpression(predicate, databaseTypeId: typeId) {
        return String(format: String(localized: "The condition of index %@ cannot be written as SQL."), index.name)
    }
    return nil
}

internal func sqliteCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
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

/// `isInlinePrimaryKey` says whether to declare `PRIMARY KEY` on this column, so a key named only by
/// `definition.primaryKeyColumns` still reaches the DDL along with the `AUTOINCREMENT` that only
/// this arm writes.
internal func sqliteColumnDefinitionSQL(
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

/// `CONSTRAINT name` is optional in SQLite's table-constraint grammar, so it is written when there
/// is a name and left out when there is not. This used to drop the name unconditionally, so a name
/// the user typed never reached the database.
///
/// The referenced column list is omitted rather than emitted empty: `REFERENCES "t" ()` is a syntax
/// error, while `REFERENCES "t"` means the parent's primary key, which is what an empty list asks
/// for. SQLite has no cross-schema foreign key, so `referencedSchema` is deliberately not written.
internal func sqliteForeignKeyDefinitionSQL(_ foreignKey: PluginForeignKeyDefinition) -> String {
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
