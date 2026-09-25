//
//  SchemaServiceDatabaseSwitchTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class DatabaseCatalogDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var schemasToReturn: [String] = []
    var tablesBySchema: [String: [TableInfo]] = [:]
    var tablesError: Error?
    private(set) var tableFetches: [String] = []

    var pausesNextTableFetch = false
    var onTableFetchPaused: (@Sendable () -> Void)?
    private var tableFetchGate: CheckedContinuation<Void, Never>?

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    func resumeTableFetch() {
        tableFetchGate?.resume()
        tableFetchGate = nil
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
        schemasToReturn
    }

    func fetchTables() async throws -> [TableInfo] { [] }

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let schema = schema ?? ""
        tableFetches.append(schema)
        if let tablesError { throw tablesError }
        let snapshot = tablesBySchema[schema] ?? []
        if pausesNextTableFetch {
            pausesNextTableFetch = false
            await withCheckedContinuation { continuation in
                tableFetchGate = continuation
                onTableFetchPaused?()
            }
        }
        return snapshot
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

/// Snowflake and Trino change database on a live connection, and a schema name such as `PUBLIC`
/// exists in every database they reach.
@MainActor
struct SchemaServiceDatabaseSwitchTests {
    private let connectionId = UUID()
    private let boom = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])

    private var connection: DatabaseConnection {
        TestFixtures.makeConnection(id: connectionId, type: .snowflake)
    }

    private func scope(_ database: String) -> DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: database, schema: nil)
    }

    private func table(_ name: String, _ schema: String) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: nil, schema: schema)
    }

    private func driver(schemas: [String], tables: [String: [TableInfo]] = [:]) -> DatabaseCatalogDriver {
        let driver = DatabaseCatalogDriver(connection: connection)
        driver.schemasToReturn = schemas
        driver.tablesBySchema = tables
        return driver
    }

    private func browse(_ service: SchemaService, database: String, driver: DatabaseCatalogDriver) async {
        await service.reload(connectionId: connectionId, driver: driver, connection: connection, scope: scope(database))
    }

    private func loadObjects(
        _ service: SchemaService,
        schema: String,
        database: String,
        driver: DatabaseCatalogDriver
    ) async {
        await service.loadSchemaObjects(schema: schema, in: scope(database), driver: driver)
    }

    private func refreshObjects(_ service: SchemaService, database: String, driver: DatabaseCatalogDriver) async {
        await service.refreshLoadedSchemaObjects(in: scope(database), fetchingNow: ["PUBLIC", "LEDGER"], driver: driver)
    }

    private func sales() -> DatabaseCatalogDriver {
        driver(schemas: ["PUBLIC", "LEDGER"], tables: [
            "PUBLIC": [table("ORDERS", "PUBLIC")],
            "LEDGER": [table("ENTRIES", "LEDGER")]
        ])
    }

    private func marketing() -> DatabaseCatalogDriver {
        driver(schemas: ["PUBLIC"], tables: ["PUBLIC": [table("CAMPAIGNS", "PUBLIC")]])
    }

    @Test("A schema of the database switched to never shows the tables of the one left")
    func switchDoesNotCarryTablesAcross() async {
        let service = SchemaService()
        let salesDriver = sales()
        await browse(service, database: "SALES", driver: salesDriver)
        await loadObjects(service, schema: "PUBLIC", database: "SALES", driver: salesDriver)
        #expect(service.tables(for: connectionId, schema: "PUBLIC").map(\.name) == ["ORDERS"])

        await browse(service, database: "MARKETING", driver: marketing())

        #expect(service.schemas(for: connectionId) == ["PUBLIC"])
        #expect(service.tables(for: connectionId, schema: "PUBLIC").isEmpty)
        #expect(service.schemaState(for: connectionId, schema: "PUBLIC") == .idle)
        #expect(service.routinesLoadState(for: connectionId, schema: "PUBLIC") == .idle)
        #expect(service.allLoadedTables(for: connectionId).isEmpty)
        #expect(service.schemasWithLoadedTables(for: connectionId).isEmpty)
    }

    @Test("A schema whose load fails after a switch reports the failure, not the old database")
    func failedLoadAfterSwitchShowsNoOldTables() async {
        let service = SchemaService()
        let salesDriver = sales()
        await browse(service, database: "SALES", driver: salesDriver)
        await loadObjects(service, schema: "PUBLIC", database: "SALES", driver: salesDriver)
        let marketingDriver = marketing()
        await browse(service, database: "MARKETING", driver: marketingDriver)

        marketingDriver.tablesError = boom
        await loadObjects(service, schema: "PUBLIC", database: "MARKETING", driver: marketingDriver)

        #expect(marketingDriver.tableFetches == ["PUBLIC"])
        #expect(service.tables(for: connectionId, schema: "PUBLIC").isEmpty)
        #expect(service.schemaState(for: connectionId, schema: "PUBLIC") == .failed("boom"))
    }

    @Test("Refreshing after a switch reads nothing on behalf of the database left")
    func refreshAfterSwitchReadsNothingForTheOldDatabase() async {
        let service = SchemaService()
        let salesDriver = sales()
        await browse(service, database: "SALES", driver: salesDriver)
        await loadObjects(service, schema: "PUBLIC", database: "SALES", driver: salesDriver)
        await loadObjects(service, schema: "LEDGER", database: "SALES", driver: salesDriver)
        let marketingDriver = marketing()
        await browse(service, database: "MARKETING", driver: marketingDriver)

        await refreshObjects(service, database: "MARKETING", driver: marketingDriver)

        #expect(marketingDriver.tableFetches.isEmpty)
        #expect(service.tables(for: connectionId, schema: "LEDGER").isEmpty)
    }

    @Test("A load for the database left that finishes after the switch is not shown")
    func lateLoadFromTheOldDatabaseIsDiscarded() async {
        let service = SchemaService()
        let salesDriver = sales()
        await browse(service, database: "SALES", driver: salesDriver)

        salesDriver.pausesNextTableFetch = true
        var late: Task<Void, Never>?
        await withCheckedContinuation { (paused: CheckedContinuation<Void, Never>) in
            salesDriver.onTableFetchPaused = { paused.resume() }
            late = Task { await loadObjects(service, schema: "PUBLIC", database: "SALES", driver: salesDriver) }
        }
        await browse(service, database: "MARKETING", driver: marketing())
        salesDriver.resumeTableFetch()
        await late?.value

        #expect(service.tables(for: connectionId, schema: "PUBLIC").isEmpty)
        #expect(service.allLoadedTables(for: connectionId).isEmpty)
    }

    /// The sidebar reads the database being switched to as soon as the switch is made, while the
    /// schema list of the one being left is still on screen.
    @Test("Objects loaded for the new database before its schema list arrives are kept")
    func loadForTheNewDatabaseDuringTheSwitchIsKept() async {
        let service = SchemaService()
        let salesDriver = sales()
        await browse(service, database: "SALES", driver: salesDriver)
        await loadObjects(service, schema: "PUBLIC", database: "SALES", driver: salesDriver)
        let marketingDriver = marketing()

        await loadObjects(service, schema: "PUBLIC", database: "MARKETING", driver: marketingDriver)
        #expect(service.tables(for: connectionId, schema: "PUBLIC").map(\.name) == ["ORDERS"])

        await browse(service, database: "MARKETING", driver: marketingDriver)
        await loadObjects(service, schema: "PUBLIC", database: "MARKETING", driver: marketingDriver)

        #expect(service.tables(for: connectionId, schema: "PUBLIC").map(\.name) == ["CAMPAIGNS"])
        #expect(marketingDriver.tableFetches == ["PUBLIC"])
    }

    @Test("Switching back lists the first database's objects again once they are loaded")
    func switchingBackReadsTheFirstDatabase() async {
        let service = SchemaService()
        let salesDriver = sales()
        await browse(service, database: "SALES", driver: salesDriver)
        await loadObjects(service, schema: "PUBLIC", database: "SALES", driver: salesDriver)
        let marketingDriver = marketing()
        await browse(service, database: "MARKETING", driver: marketingDriver)
        await loadObjects(service, schema: "PUBLIC", database: "MARKETING", driver: marketingDriver)

        await browse(service, database: "SALES", driver: salesDriver)
        await loadObjects(service, schema: "PUBLIC", database: "SALES", driver: salesDriver)

        #expect(service.tables(for: connectionId, schema: "PUBLIC").map(\.name) == ["ORDERS"])
        #expect(salesDriver.tableFetches == ["PUBLIC", "PUBLIC"])
    }
}
