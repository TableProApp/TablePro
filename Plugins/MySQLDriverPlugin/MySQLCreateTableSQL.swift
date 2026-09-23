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

internal enum MySQLIndexKeyPart: Equatable {
    case column(String, prefixLength: Int?)
    case expression(String)

    var text: String {
        switch self {
        case .column(let name, _): return name
        case .expression(let expression): return expression
        }
    }

    var sql: String {
        switch self {
        case .column(let name, let prefixLength?): return "\(mysqlQuoteIdentifier(name))(\(prefixLength))"
        case .column(let name, nil): return mysqlQuoteIdentifier(name)
        case .expression(let expression): return "(\(expression))"
        }
    }
}

internal struct MySQLIndexKey: Equatable {
    let part: MySQLIndexKeyPart
    let isDescending: Bool

    var sql: String {
        isDescending ? "\(part.sql) DESC" : part.sql
    }
}

internal func mysqlIndexKeyClause(_ keys: [MySQLIndexKey], type: String?) -> String {
    var clause = "(\(keys.map(\.sql).joined(separator: ", ")))"
    let upperType = type?.uppercased() ?? ""
    if upperType == "BTREE" || upperType == "HASH" {
        clause += " USING \(upperType)"
    }
    return clause
}

internal func mysqlIndexKeys(of index: PluginIndexDefinition) -> [MySQLIndexKey] {
    let expressions = Set(index.expressions ?? [])
    return index.columns.map { column in
        let part: MySQLIndexKeyPart = expressions.contains(column)
            ? .expression(column)
            : .column(column, prefixLength: index.columnPrefixes?[column])
        return MySQLIndexKey(part: part, isDescending: false)
    }
}

internal func mysqlIndexDefinitionSQL(_ index: PluginIndexDefinition) -> String {
    let upperType = index.indexType?.uppercased() ?? ""
    let kind: String
    switch upperType {
    case "FULLTEXT": kind = "FULLTEXT INDEX"
    case "SPATIAL": kind = "SPATIAL INDEX"
    default: kind = index.isUnique ? "UNIQUE INDEX" : "INDEX"
    }
    let keys = index.ddlMethodAndKeys?.nilIfEmpty
        ?? mysqlIndexKeyClause(mysqlIndexKeys(of: index), type: upperType)
    return "\(kind) \(mysqlQuoteIdentifier(index.name)) \(keys)"
}

internal func mysqlModifyIndexSQL(
    table: String,
    oldIndexName: String,
    newIndex: PluginIndexDefinition,
    flavor: MySQLServerFlavor
) -> String? {
    guard flavor == .mysql || flavor == .mariadb else { return nil }
    return "ALTER TABLE \(mysqlQuoteIdentifier(table)) DROP INDEX \(mysqlQuoteIdentifier(oldIndexName)), "
        + "ADD \(mysqlIndexDefinitionSQL(newIndex))"
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
