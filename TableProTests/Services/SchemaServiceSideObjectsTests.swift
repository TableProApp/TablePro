//
//  SchemaServiceSideObjectsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class SideObjectsMockDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var tablesToReturn: [TableInfo] = []
    var tablesError: Error?
    var tablesBySchema: [String: [TableInfo]] = [:]
    var routinesBySchema: [String: [RoutineInfo]] = [:]
    var routinesError: Error?
    var triggersBySchema: [String: [TriggerInfo]] = [:]
    var routineSchemaRequests: [String?] = []
    var triggerSchemaRequests: [String?] = []

    init(connection: DatabaseConnection) {
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

    func fetchTables() async throws -> [TableInfo] {
        if let tablesError { throw tablesError }
        return tablesToReturn
    }

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        tablesBySchema[schema ?? ""] ?? []
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
    func fetchSchemas() async throws -> [String] { [] }

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

    func fetchRoutines(schema: String?) async throws -> [RoutineInfo] {
        routineSchemaRequests.append(schema)
        if let routinesError { throw routinesError }
        return routinesBySchema[schema ?? ""] ?? []
    }

    func fetchAllTriggers(schema: String?) async throws -> [TriggerInfo] {
        triggerSchemaRequests.append(schema)
        return triggersBySchema[schema ?? ""] ?? []
    }
}

@Suite("SchemaService side objects")
@MainActor
struct SchemaServiceSideObjectsTests {
    private let boom = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])

    private func makeDriver() -> (UUID, DatabaseConnection, SideObjectsMockDriver) {
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        return (connectionId, connection, SideObjectsMockDriver(connection: connection))
    }

    private func procedure(_ name: String, schema: String = "public") -> RoutineInfo {
        RoutineInfo(name: name, kind: .procedure, schema: schema)
    }

    // MARK: - Connection-wide load

    /// The reported bug: a database with no tables and one stored procedure. Its routines have to
    /// settle as loaded, because the sidebar tells "still coming" from "none" by this state alone.
    @Test("A database with no tables settles its routines as loaded")
    func zeroTableDatabaseSettlesRoutines() async {
        let (connectionId, connection, driver) = makeDriver()
        driver.routinesBySchema[""] = [procedure("close_month")]

        let service = SchemaService()
        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.tables(for: connectionId).isEmpty)
        #expect(service.routinesLoadState(for: connectionId) == .loaded([procedure("close_month")]))
        #expect(service.procedures(for: connectionId).map(\.name) == ["close_month"])
    }

    /// A failed first fetch used to come back as an empty list, so a database whose procedures could
    /// not be read looked exactly like a database with none.
    @Test("A routine fetch that fails on first load is reported, not read as no routines")
    func firstLoadFailureIsReported() async {
        let (connectionId, connection, driver) = makeDriver()
        driver.routinesError = boom

        let service = SchemaService()
        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.routinesLoadState(for: connectionId) == .failed("boom"))
        #expect(service.routines(for: connectionId).isEmpty)
        #expect(service.hasLoadedContent(for: connectionId))
    }

    /// The side kinds used to be committed only after the tables succeeded, so a failed tables
    /// fetch left every Procedures and Functions section waiting on a load that had already ended.
    @Test("A failed tables fetch still settles routines")
    func failedTablesStillSettleRoutines() async {
        let (connectionId, connection, driver) = makeDriver()
        driver.tablesError = boom
        driver.routinesBySchema[""] = [procedure("close_month")]

        let service = SchemaService()
        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.state(for: connectionId) == .failed("boom"))
        #expect(service.routinesLoadState(for: connectionId) == .loaded([procedure("close_month")]))
    }

    @Test("Reloading routines after a failed first fetch replaces the failure")
    func reloadAfterFailureRecovers() async {
        let (connectionId, connection, driver) = makeDriver()
        driver.routinesError = boom
        let service = SchemaService()
        await service.load(connectionId: connectionId, driver: driver, connection: connection)
        #expect(service.routinesLoadState(for: connectionId) == .failed("boom"))

        driver.routinesError = nil
        driver.routinesBySchema[""] = [procedure("close_month")]
        let reloaded = await service.reloadRoutines(connectionId: connectionId, driver: driver, scope: nil)

        #expect(reloaded)
        #expect(service.routinesLoadState(for: connectionId) == .loaded([procedure("close_month")]))
    }

    @Test("A failed routine reload reports false and keeps the routines already loaded")
    func failedReloadKeepsRoutines() async {
        let (connectionId, connection, driver) = makeDriver()
        driver.routinesBySchema[""] = [procedure("close_month")]
        let service = SchemaService()
        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        driver.routinesError = boom
        let reloaded = await service.reloadRoutines(connectionId: connectionId, driver: driver, scope: nil)

        #expect(!reloaded)
        #expect(service.routinesLoadState(for: connectionId) == .loaded([procedure("close_month")]))
    }

    // MARK: - One schema at a time

    /// Oracle, Snowflake, BigQuery, Dameng and Trino list their objects one schema at a time, and
    /// their schema rows never asked for anything but tables.
    @Test("Expanding a schema loads that schema's routines and triggers beside its tables")
    func schemaLoadFetchesSideObjects() async {
        let (connectionId, _, driver) = makeDriver()
        driver.routinesBySchema["hr"] = [procedure("raise_salary", schema: "hr")]
        driver.triggersBySchema["hr"] = [
            TriggerInfo(name: "audit_pay", timing: "BEFORE", event: "UPDATE", statement: "", table: "pay")
        ]

        let service = SchemaService()
        await service.loadSchemaObjects(connectionId: connectionId, schema: "hr", driver: driver)

        #expect(service.tables(for: connectionId, schema: "hr").isEmpty)
        #expect(service.routines(for: connectionId, schema: "hr").map(\.name) == ["raise_salary"])
        #expect(service.triggers(for: connectionId, schema: "hr").map(\.name) == ["audit_pay"])
        #expect(driver.routineSchemaRequests == ["hr"])
        #expect(driver.triggerSchemaRequests == ["hr"])
        #expect(service.routines(for: connectionId, schema: "finance").isEmpty)
        #expect(service.isSchemaSettled(for: connectionId, schema: "hr"))
        #expect(!service.isSchemaSettled(for: connectionId, schema: "finance"))
    }

    @Test("A schema's failed routine fetch is reported and leaves its tables loaded")
    func schemaRoutineFailureIsReported() async {
        let (connectionId, _, driver) = makeDriver()
        driver.tablesBySchema["hr"] = [TableInfo(name: "pay", type: .table, rowCount: nil, schema: "hr")]
        driver.routinesError = boom

        let service = SchemaService()
        await service.loadSchemaObjects(connectionId: connectionId, schema: "hr", driver: driver)

        #expect(service.tables(for: connectionId, schema: "hr").map(\.name) == ["pay"])
        #expect(service.routinesLoadState(for: connectionId, schema: "hr") == .failed("boom"))
    }

    /// A search drops a schema only once everything in it has answered. A routine list that failed
    /// has not, and dropping the schema hid both its error and the object the user searched for.
    @Test("A schema whose routine fetch failed is not settled for a search")
    func failedSideFetchLeavesSchemaUnsettled() async {
        let (connectionId, _, driver) = makeDriver()
        driver.routinesError = boom

        let service = SchemaService()
        await service.loadSchemaObjects(connectionId: connectionId, schema: "hr", driver: driver)

        #expect(service.hasLoadedContent(for: connectionId, schema: "hr"))
        #expect(!service.isSchemaSettled(for: connectionId, schema: "hr"))
    }

    @Test("Reloading a schema keeps its routines when the refresh fails")
    func schemaReloadKeepsRoutinesOnFailure() async {
        let (connectionId, _, driver) = makeDriver()
        driver.routinesBySchema["hr"] = [procedure("raise_salary", schema: "hr")]
        let service = SchemaService()
        await service.loadSchemaObjects(connectionId: connectionId, schema: "hr", driver: driver)

        driver.routinesError = boom
        await service.reloadSchemaObjects(connectionId: connectionId, schema: "hr", driver: driver)

        #expect(service.routines(for: connectionId, schema: "hr").map(\.name) == ["raise_salary"])
    }

    @Test("Invalidating a connection clears every schema's routines")
    func invalidateClearsSchemaSideObjects() async {
        let (connectionId, _, driver) = makeDriver()
        driver.routinesBySchema["hr"] = [procedure("raise_salary", schema: "hr")]
        let service = SchemaService()
        await service.loadSchemaObjects(connectionId: connectionId, schema: "hr", driver: driver)

        await service.invalidate(connectionId: connectionId)

        #expect(service.routinesLoadState(for: connectionId, schema: "hr") == .idle)
        #expect(!service.isSchemaSettled(for: connectionId, schema: "hr"))
    }
}
