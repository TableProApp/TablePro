import Foundation
import TableProPluginKit
import TableProTrinoCore

extension TrinoPluginDriver {
    var currentCatalog: String? {
        session.catalog
    }

    func resolveSchema(_ schema: String?) -> String? {
        if let schema, !schema.isEmpty { return schema }
        return session.schema
    }

    func qualifiedName(table: String, schema: String?) -> String {
        TrinoIntrospectionSQL.qualifiedName(catalog: currentCatalog, schema: resolveSchema(schema), table: table)
    }

    func columnTypeKey(schema: String?, table: String) -> String {
        "\(resolveSchema(schema) ?? "").\(table)"
    }

    func text(_ cell: PluginCellValue?) -> String? {
        if case .text(let value)? = cell { return value }
        return nil
    }

    private func firstText(_ row: [PluginCellValue]) -> String? {
        text(row.first)
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
        let materialized = await materializedViewNames(catalog: catalog, schema: targetSchema)

        var tables: [PluginTableInfo] = []
        var seen: Set<String> = []
        for row in result.rows {
            guard let name = firstText(row) else { continue }
            seen.insert(name)
            let kind = row.count > 1 ? text(row[1]) : nil
            let type = materialized.contains(name) ? "MATERIALIZED VIEW" : Self.tableType(kind)
            tables.append(PluginTableInfo(name: name, type: type, schema: targetSchema, comment: nil))
        }
        for name in materialized.sorted() where !seen.contains(name) {
            tables.append(PluginTableInfo(name: name, type: "MATERIALIZED VIEW", schema: targetSchema, comment: nil))
        }
        return tables
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        guard let catalog = currentCatalog, let targetSchema = resolveSchema(schema) else { return [] }
        let result = try await execute(
            query: TrinoIntrospectionSQL.listColumns(catalog: catalog, schema: targetSchema, table: table)
        )
        var types: [String: String] = [:]
        let columns = result.rows.map { row -> PluginColumnInfo in
            let name = text(row.first) ?? ""
            let dataType = row.count > 1 ? text(row[1]) ?? "" : ""
            let nullable = (row.count > 2 ? text(row[2]) : nil)?.uppercased() != "NO"
            let defaultValue = Self.normalizedText(row.count > 3 ? text(row[3]) : nil)
            let comment = Self.normalizedText(row.count > 4 ? text(row[4]) : nil)
            types[name] = dataType
            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: nullable,
                defaultValue: defaultValue,
                comment: comment
            )
        }
        cacheColumnTypes(types, key: columnTypeKey(schema: targetSchema, table: table))
        return columns
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        []
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let result = try await execute(query: "SHOW CREATE TABLE \(qualifiedName(table: table, schema: schema))")
        return result.rows.compactMap { firstText($0) }.joined(separator: "\n")
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let result = try await execute(query: "SHOW CREATE VIEW \(qualifiedName(table: view, schema: schema))")
        return result.rows.compactMap { firstText($0) }.joined(separator: "\n")
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let rowCount = try? await fetchApproximateRowCount(table: table, schema: schema)
        let comment = await tableComment(table: table, schema: schema)
        return PluginTableMetadata(
            tableName: table,
            rowCount: rowCount.flatMap { $0 }.map { Int64($0) },
            comment: comment
        )
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        guard currentCatalog != nil else { return nil }
        let sql = TrinoIntrospectionSQL.approximateRowCount(
            catalog: currentCatalog, schema: resolveSchema(schema), table: table
        )
        guard let result = try? await execute(query: sql) else { return nil }
        for row in result.rows {
            guard case .null? = row.first, row.count > 4, let value = text(row[4]), let count = Double(value) else {
                continue
            }
            return Int(count)
        }
        return nil
    }

    private func tableComment(table: String, schema: String?) async -> String? {
        guard let catalog = currentCatalog, let targetSchema = resolveSchema(schema) else { return nil }
        let sql = TrinoIntrospectionSQL.tableComment(catalog: catalog, schema: targetSchema, table: table)
        let result = try? await execute(query: sql)
        return Self.normalizedText(text(result?.rows.first?.first))
    }

    private func materializedViewNames(catalog: String, schema: String) async -> Set<String> {
        let sql = TrinoIntrospectionSQL.listMaterializedViews(catalog: catalog, schema: schema)
        guard let result = try? await execute(query: sql) else { return [] }
        return Set(result.rows.compactMap { firstText($0) })
    }

    private static func tableType(_ kind: String?) -> String {
        (kind ?? "").uppercased().contains("VIEW") ? "VIEW" : "TABLE"
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
    }
}
