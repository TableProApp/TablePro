//
//  SchemaServiceHierarchicalTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class HierarchicalMockDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var schemasToReturn: [String] = []
    var tablesBySchema: [String: [TableInfo]] = [:]
    var fetchTablesCallCount: [String: Int] = [:]
    var fetchSchemasCallCount = 0

    init(connection: DatabaseConnection = TestFixtures.makeConnection()) {
        self.connection = connection
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func applyQueryTimeout(_ seconds: Int) async throws {}

    func execute(query: String) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func fetchSchemas() async throws -> [String] {
        fetchSchemasCallCount += 1
        return schemasToReturn
    }

    func fetchTables() async throws -> [TableInfo] { [] }

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let key = schema ?? ""
        fetchTablesCallCount[key, default: 0] += 1
        return tablesBySchema[key] ?? []
    }

    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchViewDefinition(view: String) async throws -> String { "" }

    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName, dataSize: nil, indexSize: nil, totalSize: nil,
            avgRowLength: nil, rowCount: nil, comment: nil, engine: nil,
            collation: nil, createTime: nil, updateTime: nil
        )
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database, name: database, tableCount: nil, sizeBytes: nil,
            lastAccessed: nil, isSystemDatabase: false, icon: "cylinder"
        )
    }

    func cancelQuery() throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}

@Suite("SchemaService hierarchical schema")
@MainActor
struct SchemaServiceHierarchicalTests {
    private func bigQueryTable(_ name: String, schema: String) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: nil, schema: schema)
    }

    @Test("BigQuery resolves to hierarchicalSchema grouping while Postgres stays bySchema")
    func groupingStrategyResolution() {
        #expect(PluginManager.shared.databaseGroupingStrategy(for: .bigQuery) == .hierarchicalSchema)
        #expect(PluginManager.shared.databaseGroupingStrategy(for: .postgresql) == .bySchema)
    }

    @Test("loadSchemaTables stores tables per schema without touching other schemas")
    func perSchemaStorage() async {
        let service = SchemaService()
        let connectionId = UUID()
        let driver = HierarchicalMockDriver()
        driver.tablesBySchema = [
            "analytics": [bigQueryTable("events", schema: "analytics"), bigQueryTable("sessions", schema: "analytics")],
            "marketing": [bigQueryTable("campaigns", schema: "marketing")]
        ]

        await service.loadSchemaTables(connectionId: connectionId, schema: "analytics", driver: driver)

        #expect(service.tables(for: connectionId, schema: "analytics").map(\.name) == ["events", "sessions"])
        #expect(service.tables(for: connectionId, schema: "marketing").isEmpty)
        #expect(driver.fetchTablesCallCount["analytics"] == 1)
        #expect(driver.fetchTablesCallCount["marketing"] == nil)
    }

    @Test("loadSchemaTables is idempotent once a schema is loaded")
    func loadIsIdempotent() async {
        let service = SchemaService()
        let connectionId = UUID()
        let driver = HierarchicalMockDriver()
        driver.tablesBySchema = ["analytics": [bigQueryTable("events", schema: "analytics")]]

        await service.loadSchemaTables(connectionId: connectionId, schema: "analytics", driver: driver)
        await service.loadSchemaTables(connectionId: connectionId, schema: "analytics", driver: driver)

        #expect(driver.fetchTablesCallCount["analytics"] == 1)
    }

    @Test("reloadSchemaTables refetches a single schema")
    func reloadRefetches() async {
        let service = SchemaService()
        let connectionId = UUID()
        let driver = HierarchicalMockDriver()
        driver.tablesBySchema = ["analytics": [bigQueryTable("events", schema: "analytics")]]

        await service.loadSchemaTables(connectionId: connectionId, schema: "analytics", driver: driver)
        driver.tablesBySchema["analytics"] = [
            bigQueryTable("events", schema: "analytics"),
            bigQueryTable("clicks", schema: "analytics")
        ]
        await service.reloadSchemaTables(connectionId: connectionId, schema: "analytics", driver: driver)

        #expect(driver.fetchTablesCallCount["analytics"] == 2)
        #expect(service.tables(for: connectionId, schema: "analytics").map(\.name) == ["events", "clicks"])
    }

    @Test("hierarchical load fills the schema list and leaves the flat table list empty")
    func hierarchicalLoadPopulatesSchemasOnly() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .bigQuery)
        let driver = HierarchicalMockDriver(connection: connection)
        driver.schemasToReturn = ["analytics", "marketing", "staging"]
        driver.tablesBySchema = ["analytics": [bigQueryTable("events", schema: "analytics")]]

        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.schemas(for: connectionId) == ["analytics", "marketing", "staging"])
        #expect(service.tables(for: connectionId).isEmpty)
        #expect(driver.fetchTablesCallCount.isEmpty)
        if case .loaded = service.state(for: connectionId) {} else {
            Issue.record("expected loaded state for hierarchical connection")
        }
    }

    @Test("invalidate clears per-schema state")
    func invalidateClearsPerSchema() async {
        let service = SchemaService()
        let connectionId = UUID()
        let driver = HierarchicalMockDriver()
        driver.tablesBySchema = ["analytics": [bigQueryTable("events", schema: "analytics")]]

        await service.loadSchemaTables(connectionId: connectionId, schema: "analytics", driver: driver)
        #expect(!service.tables(for: connectionId, schema: "analytics").isEmpty)

        await service.invalidate(connectionId: connectionId)

        #expect(service.tables(for: connectionId, schema: "analytics").isEmpty)
    }
}
