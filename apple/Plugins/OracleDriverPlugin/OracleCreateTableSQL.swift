//
//  OracleCreateTableSQL.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit

// Oracle runs one statement per call: sent as one text, the table and its indexes fail with ORA-03405 and create
// nothing. So each element is one statement.
nonisolated enum OracleCreateTableSQL {
    static func statements(
        definition: PluginCreateTableDefinition,
        schema: String,
        supportsIdentity: Bool
    ) -> [String]? {
        guard let statements = tableAndIndexStatements(
            definition: definition, schema: schema, supportsIdentity: supportsIdentity
        ) else { return nil }
        let comments = OracleColumnStatements.commentStatements(
            qualifiedTable: qualifiedTable(definition.tableName, schema: schema), columns: definition.columns
        )
        return statements + comments
    }

    static func tableAndIndexStatements(
        definition: PluginCreateTableDefinition,
        schema: String,
        supportsIdentity: Bool
    ) -> [String]? {
        guard !definition.columns.isEmpty else { return nil }

        let qualifiedTable = Self.qualifiedTable(definition.tableName, schema: schema)
        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        let inlinePK = pkColumns.count == 1
        var parts: [String] = definition.columns.map {
            columnDefinition($0, inlinePrimaryKey: inlinePK, supportsIdentity: supportsIdentity)
        }

        if pkColumns.count > 1 {
            let pkCols = pkColumns.map { quote($0.name) }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(pkCols))")
        }

        for fk in definition.foreignKeys {
            parts.append(foreignKeyConstraint(fk))
        }

        let createTable = "CREATE TABLE \(qualifiedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n)"
        let indexStatements = definition.indexes.map { indexDefinition($0, qualifiedTable: qualifiedTable) }
        return [createTable] + indexStatements
    }

    static func qualifiedTable(_ table: String, schema: String) -> String {
        "\(quote(schema)).\(quote(table))"
    }

    static func columnDefinition(
        _ column: PluginColumnDefinition,
        inlinePrimaryKey: Bool,
        supportsIdentity: Bool
    ) -> String {
        OracleColumnStatements.definition(
            column,
            inlinePrimaryKey: inlinePrimaryKey,
            supportsIdentity: supportsIdentity,
            quote: quote
        )
    }

    static func indexDefinition(_ index: PluginIndexDefinition, qualifiedTable: String) -> String {
        let cols = index.columns.map { quote($0) }.joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        return "CREATE \(unique)INDEX \(quote(index.name)) ON \(qualifiedTable) (\(cols))"
    }

    static func foreignKeyConstraint(_ fk: PluginForeignKeyDefinition) -> String {
        let cols = fk.columns.map { quote($0) }.joined(separator: ", ")
        let refCols = fk.referencedColumns.map { quote($0) }.joined(separator: ", ")
        let refTable: String
        if let schema = fk.referencedSchema, !schema.isEmpty {
            refTable = "\(quote(schema)).\(quote(fk.referencedTable))"
        } else {
            refTable = quote(fk.referencedTable)
        }
        let constraint = fk.name.isEmpty ? "" : "CONSTRAINT \(quote(fk.name)) "
        var def = "\(constraint)FOREIGN KEY (\(cols)) REFERENCES \(refTable)"
        if !refCols.isEmpty {
            def += " (\(refCols))"
        }
        if fk.onDelete != "NO ACTION" {
            def += " ON DELETE \(fk.onDelete)"
        }
        return def
    }

    private static func quote(_ name: String) -> String {
        OracleObjectQueries.quoteIdentifier(name)
    }
}
