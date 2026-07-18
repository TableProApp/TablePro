import Foundation
import TableProPluginKit
import TableProTrinoCore

extension TrinoPluginDriver {
    private var currentCatalog: String? {
        session.catalog
    }

    private func resolveSchema(_ schema: String?) -> String? {
        if let schema, !schema.isEmpty { return schema }
        return session.schema
    }

    private func firstText(_ row: [PluginCellValue]) -> String? {
        text(row.first)
    }

    private func text(_ cell: PluginCellValue?) -> String? {
        if case .text(let value)? = cell { return value }
        return nil
    }

    func fetchDatabases() async throws -> [String] {
        let result = try await execute(query: TrinoIntrospectionSQL.showCatalogs())
        return result.rows.compactMap { firstText($0) }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchSchemas() async throws -> [String] {
        guard let catalog = currentCatalog else { return [] }
        let result = try await execute(query: TrinoIntrospectionSQL.showSchemas(catalog: catalog))
        return result.rows.compactMap { firstText($0) }
    }

    func switchDatabase(to database: String) async throws {
        session.setCatalog(database)
    }

    func switchSchema(to schema: String) async throws {
        session.setSchema(schema)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard let catalog = currentCatalog, let targetSchema = resolveSchema(schema) else { return [] }
        let result = try await execute(query: TrinoIntrospectionSQL.listTables(catalog: catalog, schema: targetSchema))
        return result.rows.compactMap { row in
            guard let name = firstText(row) else { return nil }
            let kind = row.count > 1 ? text(row[1]) : nil
            return PluginTableInfo(name: name, type: Self.tableType(kind), schema: targetSchema, comment: nil)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        guard let catalog = currentCatalog, let targetSchema = resolveSchema(schema) else { return [] }
        let result = try await execute(
            query: TrinoIntrospectionSQL.listColumns(catalog: catalog, schema: targetSchema, table: table)
        )
        return result.rows.map { row in
            let name = text(row.first) ?? ""
            let dataType = row.count > 1 ? text(row[1]) ?? "" : ""
            let nullable = (row.count > 2 ? text(row[2]) : nil)?.uppercased() != "NO"
            let defaultValue = Self.normalizedDefault(row.count > 3 ? text(row[3]) : nil)
            return PluginColumnInfo(name: name, dataType: dataType, isNullable: nullable, defaultValue: defaultValue)
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        []
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let result = try await execute(
            query: TrinoIntrospectionSQL.showCreateTable(catalog: currentCatalog, schema: resolveSchema(schema), table: table)
        )
        return result.rows.compactMap { firstText($0) }.joined(separator: "\n")
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let result = try await execute(
            query: TrinoIntrospectionSQL.showCreateView(catalog: currentCatalog, schema: resolveSchema(schema), view: view)
        )
        return result.rows.compactMap { firstText($0) }.joined(separator: "\n")
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    private static func tableType(_ kind: String?) -> String {
        (kind ?? "").uppercased().contains("VIEW") ? "VIEW" : "TABLE"
    }

    private static func normalizedDefault(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
    }
}
