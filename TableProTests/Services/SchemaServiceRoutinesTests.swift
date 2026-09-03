//
//  SchemaServiceRoutinesTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class RoutineMockDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var tablesToReturn: [TableInfo] = []
    var proceduresToReturn: [RoutineInfo] = []
    var functionsToReturn: [RoutineInfo] = []

    var triggersToReturn: [TriggerInfo] = []
    var proceduresCallCount = 0
    var functionsCallCount = 0
    var tablesCallCount = 0

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

    func fetchTables() async throws -> [TableInfo] {
        tablesCallCount += 1
        return tablesToReturn
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

    /// One catalog read answers both kinds, so both counters move together. They stay separate so
    /// a test can still assert which kinds came back.
    func fetchRoutines(schema: String?) async throws -> [RoutineInfo] {
        proceduresCallCount += 1
        functionsCallCount += 1
        return proceduresToReturn + functionsToReturn
    }

    func fetchAllTriggers(schema: String?) async throws -> [TriggerInfo] {
        triggersToReturn
    }
}

private final class FailingRoutineDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

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

    func fetchTables() async throws -> [TableInfo] {
        [TestFixtures.makeTableInfo(name: "users")]
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

    func fetchRoutines(schema: String?) async throws -> [RoutineInfo] {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
    }
}

private actor AsyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        for continuation in currentWaiters {
            continuation.resume()
        }
    }
}

private final class BlockingAuxiliaryDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var tablesToReturn: [TableInfo] = []
    var proceduresToReturn: [RoutineInfo] = []
    var functionsToReturn: [RoutineInfo] = []
    var schemasToReturn: [String] = []
    var routinesCallCount = 0

    let tablesGate = AsyncGate()
    let routinesGate = AsyncGate()
    let schemasGate = AsyncGate()

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

    func fetchTables() async throws -> [TableInfo] {
        await tablesGate.wait()
        return tablesToReturn
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

    func fetchSchemas() async throws -> [String] {
        await schemasGate.wait()
        return schemasToReturn
    }

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
        routinesCallCount += 1
        await routinesGate.wait()
        return proceduresToReturn + functionsToReturn
    }
}

@Suite("SchemaService routines")
@MainActor
struct SchemaServiceRoutinesTests {
    @Test("load caches procedures and functions alongside tables")
    func loadCachesRoutines() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RoutineMockDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.proceduresToReturn = [
            RoutineInfo(name: "add_user", kind: .procedure, schema: "public")
        ]
        driver.functionsToReturn = [
            RoutineInfo(name: "user_count", kind: .function, schema: "public", argumentSignature: "int")
        ]

        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.tables(for: connectionId).map(\.name) == ["users"])
        #expect(service.procedures(for: connectionId).map(\.name) == ["add_user"])
        #expect(service.functions(for: connectionId).map(\.name) == ["user_count"])
        #expect(driver.tablesCallCount == 1)
        #expect(driver.proceduresCallCount == 1)
        #expect(driver.functionsCallCount == 1)
    }

    @Test("routines() concatenates procedures then functions")
    func routinesConcatenation() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RoutineMockDriver(connection: connection)
        driver.proceduresToReturn = [
            RoutineInfo(name: "p1", kind: .procedure)
        ]
        driver.functionsToReturn = [
            RoutineInfo(name: "f1", kind: .function)
        ]

        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        let combined = service.routines(for: connectionId)
        #expect(combined.map(\.name) == ["p1", "f1"])
        #expect(combined.map(\.kind) == [.procedure, .function])
    }

    @Test("failing routine fetches leave tables loaded and routines empty")
    func failingRoutinesDoNotBlockTables() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = FailingRoutineDriver(connection: connection)

        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.tables(for: connectionId).map(\.name) == ["users"])
        #expect(service.procedures(for: connectionId).isEmpty)
        #expect(service.functions(for: connectionId).isEmpty)
        if case .loaded = service.state(for: connectionId) {
            // success: state is loaded even though routines failed
        } else {
            Issue.record("expected loaded state when only routine fetches fail")
        }
    }

    /// A refresh never clears the cache it is refreshing. The failed fetch used to come back as an
    /// empty list, indistinguishable from a database with no routines, and it was written straight
    /// over the loaded one: a single dropped connection emptied the sidebar's Procedures and
    /// Functions while the refresh still reported loaded.
    @Test("a failed routine fetch keeps the routines already loaded")
    func failedRoutineReloadKeepsPreviousRoutines() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RoutineMockDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.proceduresToReturn = [
            RoutineInfo(name: "p1", kind: .procedure)
        ]
        driver.functionsToReturn = [
            RoutineInfo(name: "f1", kind: .function)
        ]
        await service.load(connectionId: connectionId, driver: driver, connection: connection)
        #expect(service.procedures(for: connectionId).map(\.name) == ["p1"])
        #expect(service.functions(for: connectionId).map(\.name) == ["f1"])

        let failing = FailingRoutineDriver(connection: connection)
        await service.reload(connectionId: connectionId, driver: failing, connection: connection)

        #expect(service.procedures(for: connectionId).map(\.name) == ["p1"])
        #expect(service.functions(for: connectionId).map(\.name) == ["f1"])
        #expect(service.tables(for: connectionId).map(\.name) == ["users"])
    }

    @Test("invalidate clears tables and routine caches")
    func invalidateClearsAll() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RoutineMockDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "t")]
        driver.proceduresToReturn = [
            RoutineInfo(name: "p", kind: .procedure)
        ]

        await service.load(connectionId: connectionId, driver: driver, connection: connection)
        #expect(!service.procedures(for: connectionId).isEmpty)

        await service.invalidate(connectionId: connectionId)

        #expect(service.tables(for: connectionId).isEmpty)
        #expect(service.procedures(for: connectionId).isEmpty)
        #expect(service.functions(for: connectionId).isEmpty)
    }

    @Test("table state becomes loaded before auxiliary metadata finishes")
    func tableStateLoadsBeforeAuxiliaryMetadata() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = BlockingAuxiliaryDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.proceduresToReturn = [
            RoutineInfo(name: "add_user", kind: .procedure, schema: "public")
        ]
        driver.functionsToReturn = [
            RoutineInfo(name: "user_count", kind: .function, schema: "public", argumentSignature: "int")
        ]
        driver.schemasToReturn = ["public"]

        let loadTask = Task {
            await service.load(connectionId: connectionId, driver: driver, connection: connection)
        }

        await driver.tablesGate.open()
        await waitForLoadedState(service, connectionId: connectionId)

        #expect(service.tables(for: connectionId).map(\.name) == ["users"])
        #expect(service.procedures(for: connectionId).isEmpty)
        #expect(service.functions(for: connectionId).isEmpty)
        #expect(service.schemas(for: connectionId).isEmpty)

        await driver.routinesGate.open()
        await driver.schemasGate.open()
        await loadTask.value

        #expect(service.procedures(for: connectionId).map(\.name) == ["add_user"])
        #expect(service.functions(for: connectionId).map(\.name) == ["user_count"])
        #expect(service.schemas(for: connectionId) == ["public"])
    }

    /// The tables fetch was keyed by scope and the routine fetch by connection alone, so a load
    /// for the database being entered joined the in-flight routine fetch of the one being left
    /// and committed that database's routines under the new scope.
    @Test("A load for another scope never joins the routine fetch of the scope being left")
    func scopeChangeDoesNotJoinInFlightRoutineFetch() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = BlockingAuxiliaryDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.proceduresToReturn = [RoutineInfo(name: "add_user", kind: .procedure, schema: "public")]
        driver.schemasToReturn = ["public"]
        let primary = DatabaseScope(connectionId: connectionId, database: "primary", schema: "public")
        let analytics = DatabaseScope(connectionId: connectionId, database: "analytics", schema: "public")

        let primaryLoad = Task {
            await service.load(connectionId: connectionId, driver: driver, connection: connection, scope: primary)
        }
        await driver.tablesGate.open()
        await waitForLoadedState(service, connectionId: connectionId)
        await waitUntil { driver.routinesCallCount == 1 }

        let analyticsLoad = Task {
            await service.load(connectionId: connectionId, driver: driver, connection: connection, scope: analytics)
        }
        await waitUntil { driver.routinesCallCount == 2 }
        #expect(driver.routinesCallCount == 2)

        await driver.routinesGate.open()
        await driver.schemasGate.open()
        await primaryLoad.value
        await analyticsLoad.value

        #expect(service.loadedScope(for: connectionId) == analytics)
        #expect(service.procedures(for: connectionId).map(\.name) == ["add_user"])
    }

    private func waitForLoadedState(_ service: SchemaService, connectionId: UUID) async {
        while true {
            if case .loaded = service.state(for: connectionId) {
                return
            }
            await Task.yield()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
    }

    /// One catalog read answers both kinds. Asking twice was two round trips per schema for an
    /// answer one query already held.
    @Test("reloadRoutines refreshes both kinds in one catalog read")
    func reloadRoutinesIssuesOneRead() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RoutineMockDriver(connection: connection)
        driver.proceduresToReturn = [RoutineInfo(name: "p1", kind: .procedure)]
        driver.functionsToReturn = [RoutineInfo(name: "f1", kind: .function)]
        await service.load(connectionId: connectionId, driver: driver, connection: connection)
        let firstCount = driver.proceduresCallCount

        driver.proceduresToReturn = [
            RoutineInfo(name: "p1", kind: .procedure),
            RoutineInfo(name: "p2", kind: .procedure)
        ]
        driver.functionsToReturn = [RoutineInfo(name: "f2", kind: .function)]
        await service.reloadRoutines(connectionId: connectionId, driver: driver, scope: nil)

        #expect(driver.proceduresCallCount == firstCount + 1)
        #expect(service.procedures(for: connectionId).map(\.name) == ["p1", "p2"])
        #expect(service.functions(for: connectionId).map(\.name) == ["f2"])
    }

    /// A trigger list is its own fetch behind its own state, so a driver that returns none is not
    /// the same as one that never answered.
    @Test("reloadTriggers caches the database-wide trigger list")
    func reloadTriggersCaches() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RoutineMockDriver(connection: connection)
        driver.triggersToReturn = [
            TriggerInfo(name: "audit", timing: "BEFORE", event: "INSERT", statement: "", table: "orders")
        ]
        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.triggers(for: connectionId).map(\.name) == ["audit"])
        #expect(service.triggers(for: connectionId).first?.table == "orders")
    }
}
