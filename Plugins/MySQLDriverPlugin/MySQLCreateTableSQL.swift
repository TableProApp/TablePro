//
//  MySQLCreateTableSQL.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// MySQL's `CREATE TABLE` text, with no driver behind it.
///
/// Free functions beside `MySQLColumnDefinitionSQL.swift`, so the generator can be listed in the
/// test target and exercised directly. `MySQLCreateTableTests` used to sit behind
/// `#if canImport(MySQLDriverPlugin)`, and the XcodeGen target is named `MySQLDriver`, so the module
/// by that name has never existed and the whole suite compiled to nothing.
/// `isMariaDB` is threaded rather than defaulted. MariaDB and MySQL spell an expression default
/// differently, the flag is driver state that `PluginCreateTableDefinition` does not carry, and a
/// default here would silently give every MariaDB table MySQL's parentheses.
internal func mysqlCreateTableSQL(
    definition: PluginCreateTableDefinition,
    isMariaDB: Bool
) -> String? {
    guard !definition.columns.isEmpty else { return nil }

    var parts = definition.columns.map { mysqlColumnDefinitionSQL($0, isMariaDB: isMariaDB) }

    var keyColumns = definition.primaryKeyColumns
    if keyColumns.isEmpty {
        keyColumns = definition.columns.filter(\.autoIncrement).map(\.name)
    }
    if !keyColumns.isEmpty {
        parts.append("PRIMARY KEY (\(keyColumns.map(mysqlQuoteIdentifier).joined(separator: ", ")))")
    }

    parts.append(contentsOf: definition.indexes.map(mysqlIndexDefinitionSQL))
    parts.append(contentsOf: definition.foreignKeys.map(mysqlForeignKeyDefinitionSQL))

    let ifNotExists = definition.ifNotExists ? " IF NOT EXISTS" : ""
    var sql = "CREATE TABLE\(ifNotExists) \(mysqlQuoteIdentifier(definition.tableName)) (\n"
    sql += parts.map { "    \($0)" }.joined(separator: ",\n")
    sql += "\n)"

    var tableOptions: [String] = []
    if let engine = definition.engine, !engine.isEmpty {
        tableOptions.append("ENGINE=\(engine)")
    }
    if let charset = definition.charset, !charset.isEmpty {
        tableOptions.append("DEFAULT CHARSET=\(charset)")
    }
    if let collation = definition.collation, !collation.isEmpty {
        tableOptions.append("COLLATE=\(collation)")
    }
    if !tableOptions.isEmpty {
        sql += " " + tableOptions.joined(separator: " ")
    }

    return sql + ";"
}

internal func mysqlIndexDefinitionSQL(_ index: PluginIndexDefinition) -> String {
    let columns = index.columns.map { column -> String in
        let quoted = mysqlQuoteIdentifier(column)
        if let prefixes = index.columnPrefixes, let prefix = prefixes[column] {
            return "\(quoted)(\(prefix))"
        }
        return quoted
    }.joined(separator: ", ")

    let upperType = index.indexType?.uppercased() ?? ""
    var definition: String
    switch upperType {
    case "FULLTEXT": definition = "FULLTEXT INDEX"
    case "SPATIAL": definition = "SPATIAL INDEX"
    default: definition = index.isUnique ? "UNIQUE INDEX" : "INDEX"
    }

    definition += " \(mysqlQuoteIdentifier(index.name)) (\(columns))"

    if upperType == "BTREE" || upperType == "HASH" {
        definition += " USING \(upperType)"
    }

    return definition
}

/// `CONSTRAINT name` is optional in MySQL's grammar and the server invents one when it is left out,
/// so a blank name writes no clause rather than `CONSTRAINT `` `` ``, which is a syntax error.
internal func mysqlForeignKeyDefinitionSQL(_ foreignKey: PluginForeignKeyDefinition) -> String {
    let columns = foreignKey.columns.map(mysqlQuoteIdentifier).joined(separator: ", ")
    let referencedColumns = foreignKey.referencedColumns.map(mysqlQuoteIdentifier).joined(separator: ", ")
    let referencedTable: String
    if let schema = foreignKey.referencedSchema, !schema.isEmpty {
        referencedTable = "\(mysqlQuoteIdentifier(schema)).\(mysqlQuoteIdentifier(foreignKey.referencedTable))"
    } else {
        referencedTable = mysqlQuoteIdentifier(foreignKey.referencedTable)
    }

    let constraint = foreignKey.name.isEmpty
        ? ""
        : "CONSTRAINT \(mysqlQuoteIdentifier(foreignKey.name)) "
    var definition = "\(constraint)FOREIGN KEY (\(columns)) REFERENCES \(referencedTable)"
    if !referencedColumns.isEmpty {
        definition += " (\(referencedColumns))"
    }

    let onDelete = foreignKey.onDelete.uppercased()
    if onDelete != "NO ACTION" {
        definition += " ON DELETE \(onDelete)"
    }

    let onUpdate = foreignKey.onUpdate.uppercased()
    if onUpdate != "NO ACTION" {
        definition += " ON UPDATE \(onUpdate)"
    }

    return definition
}
