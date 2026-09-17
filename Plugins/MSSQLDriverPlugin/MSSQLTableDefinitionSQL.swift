//
//  MSSQLTableDefinitionSQL.swift
//  MSSQLDriverPlugin
//
//  The `CREATE TABLE`, column, index and foreign key clauses the driver writes. Pure, so what a
//  copied table's DDL says is pinned by a test without a FreeTDS connection.
//  Compiled into the test target via project.yml.
//

import Foundation
import TableProMSSQLCore
import TableProPluginKit

enum MSSQLTableDefinitionSQL {
    static func createTable(_ definition: PluginCreateTableDefinition, schema: String) -> String? {
        guard !definition.columns.isEmpty else { return nil }

        let table = qualifiedTable(definition.tableName, schema: schema)
        let primaryKey = primaryKeyClause(for: definition.indexes)
        let primaryKeyColumns = definition.columns.filter(\.isPrimaryKey)
        let inlinePrimaryKey = primaryKeyColumns.count == 1 ? primaryKey : nil
        var parts = definition.columns.map { columnDefinition($0, inlinePrimaryKey: inlinePrimaryKey) }

        if primaryKeyColumns.count > 1 {
            let columns = primaryKeyColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            parts.append("\(primaryKey) (\(columns))")
        }

        for foreignKey in definition.foreignKeys {
            parts.append(foreignKeyDefinition(foreignKey, defaultSchema: schema))
        }

        var sql = "CREATE TABLE \(table) (\n  " + parts.joined(separator: ",\n  ") + "\n);"

        let indexStatements = definition.indexes.map { indexDefinition($0, qualifiedTable: table) }
        if !indexStatements.isEmpty {
            sql += "\n\n" + indexStatements.joined(separator: ";\n") + ";"
        }
        return sql
    }

    /// A table holds one clustered index, and a primary key is clustered unless it says otherwise.
    /// So when another index on the table is `CLUSTERED`, as a copied SQL Server table's can be, the
    /// key has to be written `NONCLUSTERED` or the server refuses that index with "Cannot create more
    /// than one clustered index".
    static func primaryKeyClause(for indexes: [PluginIndexDefinition]) -> String {
        let hasClusteredIndex = indexes.contains { $0.indexType?.uppercased() == "CLUSTERED" }
        return hasClusteredIndex ? "PRIMARY KEY NONCLUSTERED" : "PRIMARY KEY"
    }

    /// - Parameter inlinePrimaryKey: the clause written after the column when it is the table's only
    ///   key column, or nil to write none.
    static func columnDefinition(_ column: PluginColumnDefinition, inlinePrimaryKey: String?) -> String {
        var definition = "\(quoteIdentifier(column.name)) \(column.dataType)"
        if column.autoIncrement {
            definition += " IDENTITY(1,1)"
        }
        definition += column.isNullable ? " NULL" : " NOT NULL"
        if let defaultValue = column.defaultValue {
            definition += " DEFAULT \(defaultValue)"
        }
        if let inlinePrimaryKey, column.isPrimaryKey {
            definition += " \(inlinePrimaryKey)"
        }
        return definition
    }

    static func indexDefinition(_ index: PluginIndexDefinition, qualifiedTable: String) -> String {
        let columns = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        let kind: String
        switch index.indexType?.uppercased() {
        case "CLUSTERED": kind = "CLUSTERED "
        case "NONCLUSTERED": kind = "NONCLUSTERED "
        default: kind = ""
        }
        return "CREATE \(unique)\(kind)INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable) (\(columns))"
    }

    /// The referenced table is schema-qualified. An unqualified name resolves against the caller's
    /// own default schema rather than the schema the table is being created in, so a foreign key
    /// pointing at `sales.orders` used to be created against whatever `orders` that login could see,
    /// or to fail with nothing naming the schema as the reason.
    static func foreignKeyDefinition(_ foreignKey: PluginForeignKeyDefinition, defaultSchema: String) -> String {
        let columns = foreignKey.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let referencedColumns = foreignKey.referencedColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let referencedSchema = foreignKey.referencedSchema.flatMap { $0.isEmpty ? nil : $0 } ?? defaultSchema
        let referencedTable = qualifiedTable(foreignKey.referencedTable, schema: referencedSchema)
        let constraint = foreignKey.name.isEmpty ? "" : "CONSTRAINT \(quoteIdentifier(foreignKey.name)) "
        var definition = "\(constraint)FOREIGN KEY (\(columns)) REFERENCES \(referencedTable)"
        if !referencedColumns.isEmpty {
            definition += " (\(referencedColumns))"
        }
        if foreignKey.onDelete != "NO ACTION" {
            definition += " ON DELETE \(foreignKey.onDelete)"
        }
        if foreignKey.onUpdate != "NO ACTION" {
            definition += " ON UPDATE \(foreignKey.onUpdate)"
        }
        return definition
    }

    static func qualifiedTable(_ table: String, schema: String) -> String {
        "\(quoteIdentifier(schema)).\(quoteIdentifier(table))"
    }

    static func quoteIdentifier(_ name: String) -> String {
        "[\(MSSQLSchemaQueries.escapeBracket(name))]"
    }
}
