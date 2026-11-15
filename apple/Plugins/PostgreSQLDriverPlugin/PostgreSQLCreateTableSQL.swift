//
//  PostgreSQLCreateTableSQL.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

nonisolated enum PostgreSQLCreateTableSQL {
    struct Parts: Equatable {
        let qualifiedTable: String
        let createTable: String
        let indexStatements: [String]
    }

    static func script(
        _ definition: PluginCreateTableDefinition,
        schema: String,
        capabilities: PostgreSQLCapabilities
    ) -> String? {
        guard let parts = parts(definition, schema: schema, capabilities: capabilities) else { return nil }
        var sql = parts.createTable + ";"
        if !parts.indexStatements.isEmpty {
            sql += "\n\n" + parts.indexStatements.joined(separator: ";\n") + ";"
        }
        return sql
    }

    static func statements(
        _ definition: PluginCreateTableDefinition,
        schema: String,
        capabilities: PostgreSQLCapabilities
    ) -> [String]? {
        guard let parts = parts(definition, schema: schema, capabilities: capabilities) else { return nil }
        let columnComments = PostgreSQLRelationSQL.columnCommentStatements(
            qualifiedTable: parts.qualifiedTable,
            columns: definition.columns
        )
        return [parts.createTable] + parts.indexStatements + columnComments
    }

    static func parts(
        _ definition: PluginCreateTableDefinition,
        schema: String,
        capabilities: PostgreSQLCapabilities
    ) -> Parts? {
        guard !definition.columns.isEmpty,
              PostgreSQLVersionedStatements.refusal(for: definition, capabilities: capabilities) == nil
        else { return nil }

        let quote = PostgreSQLObjectQueries.quoteIdentifier
        let qualifiedTable = PostgreSQLObjectQueries.qualifiedName(schema: schema, name: definition.tableName)
        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        let inlinePK = pkColumns.count == 1
        var parts: [String] = definition.columns.map {
            columnDefinition($0, inlinePK: inlinePK, capabilities: capabilities)
        }

        if pkColumns.count > 1 {
            parts.append("PRIMARY KEY (\(pkColumns.map { quote($0.name) }.joined(separator: ", ")))")
        }

        for fk in definition.foreignKeys {
            parts.append(foreignKeyDefinition(fk))
        }

        let createTable = "CREATE TABLE \(qualifiedTable) (\n  " + parts.joined(separator: ",\n  ") + "\n)"
        let indexStatements = definition.indexes.map {
            PostgreSQLIndexClauses.createStatement(for: $0, qualifiedTable: qualifiedTable)
        }
        return Parts(qualifiedTable: qualifiedTable, createTable: createTable, indexStatements: indexStatements)
    }

    static func columnDefinition(
        _ col: PluginColumnDefinition,
        inlinePK: Bool,
        capabilities: PostgreSQLCapabilities
    ) -> String {
        var def = "\(PostgreSQLObjectQueries.quoteIdentifier(col.name)) \(PostgreSQLColumnClauses.type(for: col))"
        if let collation = PostgreSQLColumnClauses.collation(for: col) {
            def += " COLLATE \(collation)"
        }
        if let expression = PostgreSQLColumnClauses.generationExpression(for: col) {
            def += " GENERATED ALWAYS AS (\(expression)) \(generationKeyword(col.generationKind, capabilities: capabilities))"
            if !col.isNullable { def += " NOT NULL" }
            // A generated column can hold the primary key, and the caller relies on the inline key being written here.
            if inlinePK && col.isPrimaryKey { def += " PRIMARY KEY" }
            return def
        }
        if !col.autoIncrement {
            def += col.isNullable ? " NULL" : " NOT NULL"
        }
        if let defaultValue = PostgreSQLColumnClauses.defaultExpression(for: col) {
            def += " DEFAULT \(defaultValue)"
        }
        if inlinePK && col.isPrimaryKey {
            def += " PRIMARY KEY"
        }
        return def
    }

    // PostgreSQL 17 and earlier refuse VIRTUAL and require STORED, while 18 made VIRTUAL the default, so the keyword is
    // always written.
    static func generationKeyword(_ kind: GenerationKind?, capabilities: PostgreSQLCapabilities) -> String {
        guard capabilities.hasVirtualGeneratedColumns else { return "STORED" }
        return (kind ?? .virtual).rawValue
    }

    static func foreignKeyDefinition(_ fk: PluginForeignKeyDefinition) -> String {
        let quote = PostgreSQLObjectQueries.quoteIdentifier
        let cols = fk.columns.map(quote).joined(separator: ", ")
        let refCols = fk.referencedColumns.map(quote).joined(separator: ", ")
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
        if fk.onUpdate != "NO ACTION" {
            def += " ON UPDATE \(fk.onUpdate)"
        }
        return def
    }
}
