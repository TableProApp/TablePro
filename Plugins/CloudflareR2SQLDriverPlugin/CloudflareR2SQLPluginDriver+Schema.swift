//
//  CloudflareR2SQLPluginDriver+Schema.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProR2SQLCore

extension CloudflareR2SQLPluginDriver {
    func fetchDatabases() async throws -> [String] {
        [connectionConfig.bucket]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchSchemas() async throws -> [String] {
        try R2SQLIntrospectionSQL.namespaces(from: try await run(sql: R2SQLIntrospectionSQL.showNamespaces))
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard let namespace = schema.flatMap({ $0.isEmpty ? nil : $0 }) ?? currentSchema else { return [] }
        let listing = try await run(sql: R2SQLIntrospectionSQL.showTables(namespace: namespace))
        return try R2SQLIntrospectionSQL.tables(from: listing).map { name in
            PluginTableInfo(name: name, type: "TABLE", schema: namespace, comment: nil)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        try await describe(table: table, schema: schema).columns.map { column in
            PluginColumnInfo(
                name: column.name,
                dataType: column.typeName,
                isNullable: column.isNullable,
                defaultValue: nil,
                comment: column.comment
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        []
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let described = try await describe(table: table, schema: schema)
        let body = described.columns
            .map { column in
                let quoted = R2SQLIntrospectionSQL.quoteIdentifier(column.name)
                return "    \(quoted) \(column.typeName)\(column.isNullable ? "" : " NOT NULL")"
            }
            .joined(separator: ",\n")
        let name = R2SQLIntrospectionSQL.quoteIdentifier(described.namespace)
            + "." + R2SQLIntrospectionSQL.quoteIdentifier(table)
        return "CREATE TABLE \(name) (\n\(body)\n)"
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw R2SQLError.unsupported("R2 SQL has no views.")
    }

    private func describe(
        table: String,
        schema: String?
    ) async throws -> (namespace: String, columns: [R2SQLColumnDescription]) {
        let namespace = try namespace(for: schema)
        let result = try await run(sql: R2SQLIntrospectionSQL.describe(namespace: namespace, table: table))
        return (namespace, try R2SQLIntrospectionSQL.columns(from: result))
    }
}
