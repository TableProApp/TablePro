import Foundation
import TableProPluginKit
import Testing

private final class SharedReadDriver: PluginDatabaseDriver, @unchecked Sendable {
    func connect() async throws {}
    func disconnect() {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        ["\(schema ?? "").orders": [PluginColumnInfo(name: "id", dataType: "bigint")]]
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        ["\(schema ?? "").orders": [PluginForeignKeyInfo(name: "fk", column: "c", referencedTable: "c", referencedColumn: "id")]]
    }

    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        ["\(schema ?? "").orders": [PluginIndexInfo(name: "orders_pkey", columns: ["id"], isPrimary: true)]]
    }
}

struct PluginExportReadDefaultsTests {
    @Test("A driver without export reads of its own answers an export with its shared reads")
    func exportReadsDefaultToTheSharedReads() async throws {
        let driver = SharedReadDriver()

        let columns = try await driver.fetchAllColumnsForExport(schema: "sales")
        let foreignKeys = try await driver.fetchAllForeignKeysForExport(schema: "sales")
        let indexes = try await driver.fetchAllIndexesForExport(schema: "sales")

        #expect(columns["sales.orders"]?.map { $0.name } == ["id"])
        #expect(foreignKeys["sales.orders"]?.map { $0.name } == ["fk"])
        #expect(indexes["sales.orders"]?.map { $0.name } == ["orders_pkey"])
    }
}
