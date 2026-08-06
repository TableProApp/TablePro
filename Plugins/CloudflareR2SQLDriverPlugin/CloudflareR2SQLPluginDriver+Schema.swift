//
//  CloudflareR2SQLPluginDriver+Schema.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProR2SQLCore

extension CloudflareR2SQLPluginDriver {
    func fetchDatabases() async throws -> [String] {
        guard let bucket = resolvedConfig?.bucket, !bucket.isEmpty else { return [] }
        return [bucket]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await run(sql: R2SQLIntrospectionSQL.showNamespaces())
        return R2SQLRowMapper.firstColumnStrings(result).sorted()
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard let namespace = resolveNamespace(schema) else { return [] }
        let result = try await run(sql: R2SQLIntrospectionSQL.showTables(namespace: namespace))
        return R2SQLRowMapper.firstColumnStrings(result).sorted().map { name in
            PluginTableInfo(name: name, type: "TABLE", schema: namespace, comment: nil)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        guard let namespace = resolveNamespace(schema) else { return [] }
        let result = try await run(sql: R2SQLIntrospectionSQL.describe(namespace: namespace, table: table))
        let mapped = R2SQLRowMapper.map(result)

        return mapped.rows.compactMap { row -> PluginColumnInfo? in
            guard let name = Self.text(row.first), !name.isEmpty else { return nil }
            let rawType = row.count > 1 ? Self.text(row[1]) ?? "" : ""
            let nullable = Self.parseNullable(row.count > 2 ? Self.text(row[2]) : nil)
            return PluginColumnInfo(
                name: name,
                dataType: R2SQLTypeMapper.displayTypeName(rawTypeName: rawType),
                isNullable: nullable,
                defaultValue: nil,
                comment: nil
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
        guard let namespace = resolveNamespace(schema) else {
            throw R2SQLError.configuration(R2SQLErrorText.noNamespace)
        }
        let columns = try await fetchColumns(table: table, schema: namespace)
        guard !columns.isEmpty else {
            throw R2SQLError.query(R2SQLAPIError(code: 0, message: "No columns found for \(table)"))
        }
        let body = columns
            .map { "    \(R2SQLLiteral.quoteIdentifier($0.name)) \($0.dataType)\($0.isNullable ? "" : " NOT NULL")" }
            .joined(separator: ",\n")
        let name = R2SQLLiteral.qualifiedName(namespace: namespace, table: table)
        return "CREATE TABLE \(name) (\n\(body)\n)"
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw R2SQLError.unsupported(R2SQLErrorText.noViews)
    }

    static func text(_ value: R2SQLValue?) -> String? {
        guard case .text(let text)? = value else { return nil }
        return text
    }

    static func parseNullable(_ value: String?) -> Bool {
        guard let value else { return true }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "NO", "FALSE", "0", "NOT NULL":
            return false
        default:
            return true
        }
    }
}
