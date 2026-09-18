//
//  SQLiteCreateTableDDL.swift
//  SQLiteDriverPlugin
//

import Foundation
import TableProPluginKit

/// SQLite's `CREATE TABLE` text, with no driver and no connection behind it.
///
/// Free functions in their own file, the shape `MySQLColumnDefinitionSQL.swift` already uses, so the
/// generator can be listed in the test target and exercised directly. Before this the SQLite DDL
/// path had no automated coverage at all, which is how a foreign key clause that silently discarded
/// the constraint name went unnoticed.
internal func sqliteQuoteIdentifier(_ name: String) -> String {
    let escaped = name.replacingOccurrences(of: "`", with: "``")
    return "`\(escaped)`"
}

internal func sqliteCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
    guard !definition.columns.isEmpty else { return nil }

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

/// The `WHERE` predicate is written, because a partial index without it is a different index: a
/// unique partial index that loses its condition rejects the rows the user meant to exclude.
internal func sqliteAddIndexSQL(table: String, index: PluginIndexDefinition) -> String {
    let columns = index.columns.map(sqliteQuoteIdentifier).joined(separator: ", ")
    let unique = index.isUnique ? "UNIQUE " : ""
    var statement = "CREATE \(unique)INDEX \(sqliteQuoteIdentifier(index.name)) "
        + "ON \(sqliteQuoteIdentifier(table)) (\(columns))"
    if let predicate = index.whereClause?.nilIfEmpty {
        statement += " WHERE \(predicate)"
    }
    return statement
}
