import Foundation
import TableProPluginKit

extension HanaPluginDriver {
    func fetchSchemas() async throws -> [String] {
        let result = try await execute(query: HanaCatalogQueries.schemas)
        return result.rows.compactMap { $0.first?.asText }
    }

    func fetchDatabases() async throws -> [String] {
        try await fetchSchemas()
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let result = try await execute(query: HanaCatalogQueries.tableCount(schema: database))
        return PluginDatabaseMetadata(
            name: database,
            tableCount: HanaCatalogMapping.integer(result.rows.first?.first),
            isSystemDatabase: HanaPlugin.systemSchemaNames.contains(database)
        )
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let owner = try effectiveSchema(schema)
        let result = try await execute(query: HanaCatalogQueries.tables(schema: owner))
        return HanaCatalogMapping.tables(from: result.rows, schema: owner)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        try await catalogColumns(table: table, schema: effectiveSchema(schema)).map(\.pluginColumn)
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let owner = try effectiveSchema(schema)
        let result = try await execute(query: HanaCatalogQueries.columns(schema: owner, table: nil))
        return HanaCatalogMapping.columnsByTable(from: result.rows)
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let owner = try effectiveSchema(schema)
        let result = try await execute(query: HanaCatalogQueries.indexes(schema: owner, table: table))
        return HanaCatalogMapping.indexes(from: result.rows)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let owner = try effectiveSchema(schema)
        let result = try await execute(query: HanaCatalogQueries.foreignKeys(schema: owner, table: table))
        return HanaCatalogMapping.foreignKeys(from: result.rows)
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let owner = try effectiveSchema(schema)
        let result = try await execute(query: HanaCatalogQueries.tableMetadata(schema: owner, table: table))
        if let row = result.rows.first {
            return HanaCatalogMapping.tableMetadata(table: table, row: row)
        }
        let view = try await execute(query: HanaCatalogQueries.viewComment(schema: owner, view: table))
        return PluginTableMetadata(tableName: table, comment: HanaCatalogMapping.nonEmptyText(view.rows.first?.first))
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let owner = try effectiveSchema(schema)
        let result = try await execute(query: HanaCatalogQueries.approximateRowCount(schema: owner, table: table))
        return HanaCatalogMapping.integer(result.rows.first?.first)
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let owner = try effectiveSchema(schema)
        let store = try await execute(query: HanaCatalogQueries.tableStore(schema: owner, table: table))
        let columns = try await catalogColumns(table: table, schema: owner)
        guard let storeRow = store.rows.first, !columns.isEmpty else {
            throw HanaError(
                kind: .missingObject,
                message: String(localized: "SAP HANA did not return the table definition.")
            )
        }
        return HanaCatalogMapping.tableDDL(
            schema: owner,
            table: table,
            isColumnTable: HanaCatalogMapping.isTrue(storeRow.first),
            columns: columns
        )
    }

    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        let owner = try effectiveSchema(schema)
        let result = try await execute(query: HanaCatalogQueries.indexes(schema: owner, table: table))
        return HanaCatalogMapping.indexStatements(schema: owner, table: table, rows: result.rows)
    }

    func fetchCommentDDL(table: String, schema: String?) async throws -> [String] {
        let owner = try effectiveSchema(schema)
        let relation = try await execute(query: HanaCatalogQueries.relationComment(schema: owner, name: table))
        let columns = try await catalogColumns(table: table, schema: owner)
        return HanaCatalogMapping.commentStatements(
            schema: owner,
            table: table,
            relation: relation.rows.first,
            columns: columns
        )
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let owner = try effectiveSchema(schema)
        let result = try await execute(query: HanaCatalogQueries.viewDefinition(schema: owner, view: view))
        guard let definition = HanaCatalogMapping.nonEmptyText(result.rows.first?.first) else {
            throw HanaError(
                kind: .missingObject,
                message: String(localized: "SAP HANA returned no definition for this view.")
            )
        }
        return HanaCatalogMapping.viewDDL(schema: owner, view: view, definition: definition)
    }

    private func catalogColumns(table: String, schema: String) async throws -> [HanaCatalogColumn] {
        let result = try await execute(query: HanaCatalogQueries.columns(schema: schema, table: table))
        return HanaCatalogMapping.columns(from: result.rows)
    }
}
