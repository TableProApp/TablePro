// Fetch All installs a query handle under the tab's id and has to retire it on every exit. The
// cancelled exit did not: it cleared the loading flag and returned, so a finished fetch stayed
// installed and the next execution on that tab read it as a live displaced entry and cancelled it.

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@Suite("Fetch All query handle", .serialized)
@MainActor
struct FetchAllQueryTaskTests {
    /// The driver runs to completion whatever the task does, which is what every driver whose
    /// `cancelQuery()` is the PluginKit no-op default does, and is why this exit exists at all.
    @Test("A fetch all cancelled while it ran still retires its query handle")
    func cancelledFetchAllRetiresItsHandle() async {
        let connection = TestFixtures.makeConnection()
        let driver = GatedQueryDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = connection.database
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        let tab = QueryTab(title: "Query", query: "SELECT 1", tabType: .query)
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        coordinator.paginationCoordinator.performFetchAll(
            tabId: tab.id,
            baseQuery: "SELECT 1",
            scope: DatabaseScope(connectionId: connection.id, database: connection.database, schema: nil)
        )

        await driver.waitUntilRunning()
        guard let handle = coordinator.queryTasks.task(for: tab.id) else {
            Issue.record("the fetch installed no query handle")
            return
        }
        handle.cancel()
        await driver.release()
        await handle.value

        #expect(coordinator.queryTasks.hasTask(for: tab.id) == false)
        #expect(coordinator.tabExecution.isBusy(tab.id) == false)
        #expect(tabManager.tabs.first { $0.id == tab.id }?.pagination.isLoadingMore == false)
    }

    @Test("Fetch All asks the gate again, and a refusal reaches no driver")
    func refusedFetchAllRunsNothing() async {
        let connection = TestFixtures.makeConnection()
        let driver = GatedQueryDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = connection.database
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        coordinator.executionGate = AlwaysDenyGate()
        // Open, so a fetch that skipped the gate would finish and be counted rather than hang.
        await driver.release()
        let tab = QueryTab(title: "Query", query: "SELECT purge_orders()", tabType: .query)
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        coordinator.paginationCoordinator.performFetchAll(
            tabId: tab.id,
            baseQuery: "SELECT purge_orders()",
            scope: DatabaseScope(connectionId: connection.id, database: connection.database, schema: nil)
        )
        await coordinator.queryTasks.task(for: tab.id)?.value

        #expect(driver.queryCount == 0)
        #expect(tabManager.tabs.first { $0.id == tab.id }?.execution.errorMessage != nil)
        #expect(tabManager.tabs.first { $0.id == tab.id }?.pagination.isLoadingMore == false)
    }

    @Test("Fetch All on a query tab shows what its own run printed, not the first run's or anything before it")
    func fetchAllReplacesTheOutput() async {
        let firstRun = PluginServerOutput(lines: ["NOTICE:  page 1"], isTruncated: false)
        let leftOver = PluginServerOutput(lines: ["NOTICE:  audit row written"], isTruncated: false)
        let refetched = PluginServerOutput(lines: ["NOTICE:  page 1", "NOTICE:  page 2"], isTruncated: false)
        let connection = TestFixtures.makeConnection()
        let driver = GatedQueryDriver(connection: connection)
        driver.serverOutputs = [leftOver, refetched]
        await driver.release()
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = connection.database
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "Query", query: "SELECT noisy()", tabType: .query)
        let shown = ResultSet(label: "Result")
        shown.serverOutput = firstRun
        tab.display.replaceUnpinnedResults(with: [shown])
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        coordinator.paginationCoordinator.performFetchAll(
            tabId: tab.id,
            baseQuery: "SELECT noisy()",
            scope: DatabaseScope(connectionId: connection.id, database: connection.database, schema: nil)
        )
        guard let handle = coordinator.queryTasks.task(for: tab.id) else {
            Issue.record("the fetch installed no query handle")
            return
        }
        await handle.value

        #expect(tabManager.tabs.first { $0.id == tab.id }?.display.activeResultSet?.serverOutput == refetched)
    }
}

/// Answers `executeUserQuery` only once the test lets it, and never by raising: a cancel has to find
/// the query already on its way back.
private final class GatedQueryDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    private let answer = AsyncGate()
    var serverOutputs: [PluginServerOutput] = []
    private let lock = NSLock()
    private var queries = 0

    var queryCount: Int {
        lock.withLock { queries }
    }

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    /// Bounded, so a fetch that never queries fails on the missing handle rather than hanging.
    func waitUntilRunning() async {
        _ = await BoundedCall.result { [answer] in await answer.arrived(1) }
    }

    func release() async {
        await answer.open()
    }

    /// The gate ignores cancellation, so the answer still comes back after the task is cancelled.
    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        lock.withLock { queries += 1 }
        await answer.wait()
        return Self.emptyResult
    }

    func fetchServerOutput() async throws -> PluginServerOutput {
        serverOutputs.isEmpty ? .none : serverOutputs.removeFirst()
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func ping() async throws {}
    func cancelQuery() throws {}
    func applyQueryTimeout(_ seconds: Int) async throws {}
    func execute(query: String) async throws -> QueryResult { Self.emptyResult }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult { Self.emptyResult }

    func fetchTables() async throws -> [TableInfo] { [] }
    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { [:] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database,
            name: database,
            tableCount: nil,
            sizeBytes: nil,
            lastAccessed: nil,
            isSystemDatabase: false,
            icon: "cylinder"
        )
    }

    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName,
            dataSize: nil,
            indexSize: nil,
            totalSize: nil,
            avgRowLength: nil,
            rowCount: nil,
            comment: nil,
            engine: nil,
            collation: nil,
            createTime: nil,
            updateTime: nil
        )
    }

    func fetchViewDefinition(view: String) async throws -> String { "" }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    private static var emptyResult: QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }
}
