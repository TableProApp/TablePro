//
//  SchemaServiceRefreshTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class RefreshMockDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var tablesToReturn: [TableInfo] = []
    var schemaTablesToReturn: [String: [TableInfo]] = [:]
    var tablesError: Error?
    var schemaTablesError: Error?
    var tablesCallCount = 0

    var pausesFetchTables = false
    var onFetchTablesSuspended: (@Sendable () -> Void)?
    private var fetchTablesGate: CheckedContinuation<Void, Never>?

    init(connection: DatabaseConnection = TestFixtures.makeConnection()) {
        self.connection = connection
    }

    func resumeFetchTables() {
        fetchTablesGate?.resume()
        fetchTablesGate = nil
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
        if pausesFetchTables {
            await withCheckedContinuation { continuation in
                fetchTablesGate = continuation
                onFetchTablesSuspended?()
            }
        }
        if let tablesError { throw tablesError }
        return tablesToReturn
    }

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        guard let schema else { return try await fetchTables() }
        if let schemaTablesError { throw schemaTablesError }
        return schemaTablesToReturn[schema] ?? []
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
    func fetchProcedures(schema: String?) async throws -> [RoutineInfo] { [] }
    func fetchFunctions(schema: String?) async throws -> [RoutineInfo] { [] }
}

@Suite("SchemaService refresh keeps content visible")
@MainActor
struct SchemaServiceRefreshTests {
    private func loadedService(
        connectionId: UUID,
        driver: RefreshMockDriver,
        connection: DatabaseConnection
    ) async -> SchemaService {
        let service = SchemaService()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        await service.load(connectionId: connectionId, driver: driver, connection: connection)
        return service
    }

    @Test("reload keeps the loaded tables visible while the refresh is in flight")
    func reloadKeepsTablesVisibleDuringRefresh() async {
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RefreshMockDriver(connection: connection)
        let service = await loadedService(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.tables(for: connectionId).map(\.name) == ["orders"])

        let suspended = AsyncStream<Void>.makeStream()
        driver.onFetchTablesSuspended = { suspended.continuation.yield() }
        driver.pausesFetchTables = true
        driver.tablesToReturn = [
            TestFixtures.makeTableInfo(name: "orders"),
            TestFixtures.makeTableInfo(name: "invoices")
        ]

        let reload = Task {
            await service.reload(connectionId: connectionId, driver: driver, connection: connection)
        }

        var iterator = suspended.stream.makeAsyncIterator()
        await iterator.next()

        #expect(service.tables(for: connectionId).map(\.name) == ["orders"])
        #expect(service.isRefreshing(connectionId: connectionId))
        if case .loading = service.state(for: connectionId) {
            Issue.record("A refresh must not drop the connection back to .loading while it holds content")
        }

        driver.resumeFetchTables()
        await reload.value

        #expect(service.tables(for: connectionId).map(\.name) == ["orders", "invoices"])
        #expect(!service.isRefreshing(connectionId: connectionId))
    }

    @Test("A load for a new scope does not adopt the in-flight load for the old scope")
    func loadsForDifferentScopesDoNotJoin() async {
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RefreshMockDriver(connection: connection)
        let service = SchemaService()
        let primary = DatabaseScope(connectionId: connectionId, database: "primary", schema: "public")
        let analytics = DatabaseScope(connectionId: connectionId, database: "analytics", schema: "reporting")

        let suspended = AsyncStream<Void>.makeStream()
        driver.onFetchTablesSuspended = { suspended.continuation.yield() }
        driver.pausesFetchTables = true
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "legacy_orders")]

        let first = Task {
            await service.reload(
                connectionId: connectionId,
                driver: driver,
                connection: connection,
                scope: primary
            )
        }
        var iterator = suspended.stream.makeAsyncIterator()
        await iterator.next()

        driver.pausesFetchTables = false
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "events")]
        let second = Task {
            await service.reload(
                connectionId: connectionId,
                driver: driver,
                connection: connection,
                scope: analytics
            )
        }
        await Task.yield()
        driver.resumeFetchTables()
        await first.value
        await second.value

        #expect(driver.tablesCallCount == 2, "Each browse scope must run its own fetch")
        #expect(service.loadedScope(for: connectionId) == analytics)
        #expect(
            service.tables(for: connectionId).map(\.name) == ["events"],
            "The new scope must not be stamped onto the previous scope's tables"
        )
    }

    @Test("refresh waiters receive tables for the requested scope")
    func refreshWaitersReceiveRequestedScope() async {
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RefreshMockDriver(connection: connection)
        let service = SchemaService()
        let firstScope = DatabaseScope(connectionId: connectionId, database: "primary", schema: "public")
        let secondScope = DatabaseScope(connectionId: connectionId, database: "analytics", schema: "reporting")

        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]
        await service.load(
            connectionId: connectionId,
            driver: driver,
            connection: connection,
            scope: firstScope
        )

        let suspended = AsyncStream<Void>.makeStream()
        driver.onFetchTablesSuspended = { suspended.continuation.yield() }
        driver.pausesFetchTables = true
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "events")]

        let reload = Task {
            await service.reload(
                connectionId: connectionId,
                driver: driver,
                connection: connection,
                scope: secondScope
            )
        }
        var iterator = suspended.stream.makeAsyncIterator()
        await iterator.next()

        #expect(service.loadedScope(for: connectionId) == firstScope)
        var waiterFinished = false
        let waiter = Task {
            await service.waitForRefresh(connectionId: connectionId)
            waiterFinished = true
        }
        await Task.yield()
        #expect(!waiterFinished)

        driver.resumeFetchTables()
        await waiter.value
        await reload.value

        #expect(service.loadedScope(for: connectionId) == secondScope)
        #expect(service.tables(for: connectionId).map(\.name) == ["events"])
    }

    @Test("a cold load still reports loading so the sidebar can show its spinner")
    func coldLoadReportsLoading() async {
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RefreshMockDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders")]

        let service = SchemaService()
        let suspended = AsyncStream<Void>.makeStream()
        driver.onFetchTablesSuspended = { suspended.continuation.yield() }
        driver.pausesFetchTables = true

        let load = Task {
            await service.load(connectionId: connectionId, driver: driver, connection: connection)
        }

        var iterator = suspended.stream.makeAsyncIterator()
        await iterator.next()

        guard case .loading = service.state(for: connectionId) else {
            Issue.record("A load with no cached content must report .loading")
            driver.resumeFetchTables()
            await load.value
            return
        }
        #expect(service.tables(for: connectionId).isEmpty)

        driver.resumeFetchTables()
        await load.value

        #expect(service.tables(for: connectionId).map(\.name) == ["orders"])
    }

    @Test("a failed refresh keeps the tables that were already loaded")
    func failedRefreshKeepsLoadedTables() async {
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RefreshMockDriver(connection: connection)
        let service = await loadedService(connectionId: connectionId, driver: driver, connection: connection)

        driver.tablesError = DatabaseError.notConnected
        await service.reload(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.tables(for: connectionId).map(\.name) == ["orders"])
        if case .failed = service.state(for: connectionId) {
            Issue.record("A failed refresh must not replace loaded tables with an error state")
        }
        #expect(!service.isRefreshing(connectionId: connectionId))
    }

    @Test("a failed cold load surfaces the failure")
    func failedColdLoadSurfacesFailure() async {
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RefreshMockDriver(connection: connection)
        driver.tablesError = DatabaseError.notConnected

        let service = SchemaService()
        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        guard case .failed = service.state(for: connectionId) else {
            Issue.record("A cold load with no cached content must surface the failure")
            return
        }
        #expect(!service.isRefreshing(connectionId: connectionId))
    }

    @Test("prepareForReload keeps cached content where invalidate clears it")
    func prepareForReloadKeepsCachedContent() async {
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RefreshMockDriver(connection: connection)
        let service = await loadedService(connectionId: connectionId, driver: driver, connection: connection)

        await service.prepareForReload(connectionId: connectionId)
        #expect(service.tables(for: connectionId).map(\.name) == ["orders"])
        #expect(service.hasLoadedContent(for: connectionId))

        await service.invalidate(connectionId: connectionId)
        #expect(service.tables(for: connectionId).isEmpty)
        #expect(!service.hasLoadedContent(for: connectionId))
        #expect(!service.isRefreshing(connectionId: connectionId))
    }

    @Test("reloading one schema keeps its previous tables visible until fresh ones arrive")
    func perSchemaReloadKeepsPreviousTables() async {
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RefreshMockDriver(connection: connection)
        driver.schemaTablesToReturn = ["sales": [TableInfo(name: "orders", type: .table, rowCount: 0, schema: "sales")]]

        let service = SchemaService()
        await service.loadSchemaTables(connectionId: connectionId, schema: "sales", driver: driver)
        #expect(service.tables(for: connectionId, schema: "sales").map(\.name) == ["orders"])

        driver.schemaTablesError = DatabaseError.notConnected
        await service.reloadSchemaTables(connectionId: connectionId, schema: "sales", driver: driver)

        #expect(service.tables(for: connectionId, schema: "sales").map(\.name) == ["orders"])
    }

    @Test("refreshLoadedSchemaTables refetches only the schemas already expanded")
    func refreshLoadedSchemaTablesRefetchesExpandedSchemas() async {
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RefreshMockDriver(connection: connection)
        driver.schemaTablesToReturn = [
            "sales": [TableInfo(name: "orders", type: .table, rowCount: 0, schema: "sales")],
            "hr": [TableInfo(name: "staff", type: .table, rowCount: 0, schema: "hr")]
        ]

        let service = SchemaService()
        await service.loadSchemaTables(connectionId: connectionId, schema: "sales", driver: driver)

        driver.schemaTablesToReturn["sales"] = [
            TableInfo(name: "orders", type: .table, rowCount: 0, schema: "sales"),
            TableInfo(name: "refunds", type: .table, rowCount: 0, schema: "sales")
        ]
        await service.refreshLoadedSchemaTables(connectionId: connectionId, driver: driver)

        #expect(service.tables(for: connectionId, schema: "sales").map(\.name) == ["orders", "refunds"])
        #expect(service.tables(for: connectionId, schema: "hr").isEmpty)
    }
}
