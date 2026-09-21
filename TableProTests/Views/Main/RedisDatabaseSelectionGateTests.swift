//
//  RedisDatabaseSelectionGateTests.swift
//  TableProTests
//
//  Selecting a Redis database moves the connection's one shared driver. It used to send its SELECT
//  around the driver gate, so the SELECT could land between a browse's SCAN and its TYPE/TTL
//  pipeline, or in the middle of a key tree load, and both then read another database's keys.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class Latch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("Redis database selection and the session driver gate", .serialized)
@MainActor
struct RedisDatabaseSelectionGateTests {
    private func makeSession() -> (connection: DatabaseConnection, recorder: RecordingRedisPluginDriver) {
        let connection = TestFixtures.makeConnection(database: "0", type: .redis)
        let recorder = RecordingRedisPluginDriver()
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: recorder)
        )
        session.status = .connected
        session.browseDatabase = "0"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, recorder)
    }

    private func makeCoordinator(for connection: DatabaseConnection) -> MainContentCoordinator {
        MainContentCoordinator(
            connection: connection,
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }

    private func cleanUp(_ connectionId: UUID) {
        DatabaseManager.shared.removeSession(for: connectionId)
        SharedSidebarState.removeConnection(connectionId)
    }

    /// Holds the connection's driver until `release` opens, and returns only once it holds it.
    private func holdDriver(_ connectionId: UUID, until release: Latch) async -> Task<Void, Error> {
        let acquired = Latch()
        let holder = Task { @MainActor in
            try await DatabaseManager.shared.sessionDriverGate.withExclusiveAccess(connectionId) {
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()
        return holder
    }

    /// The bound is there so a caller that never queues, which is the regression these tests guard,
    /// fails the assertions after it rather than hanging the suite.
    private func waitForQueuedCallers(_ count: Int, on connectionId: UUID) async {
        for _ in 0..<10_000 where DatabaseManager.shared.sessionDriverGate.waiterCount(for: connectionId) < count {
            await Task.yield()
        }
    }

    @Test("Selecting a database waits for the driver and switches once its turn comes")
    func selectionWaitsForTheDriver() async throws {
        let (connection, recorder) = makeSession()
        defer { cleanUp(connection.id) }
        let coordinator = makeCoordinator(for: connection)
        defer { coordinator.teardown() }
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        coordinator.openTableTab("db2")
        await waitForQueuedCallers(1, on: connection.id)

        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 1)
        #expect(recorder.switchedDatabases.isEmpty)

        release.open()
        try await holder.value
        await coordinator.redisDatabaseSwitchTask?.value

        #expect(recorder.switchedDatabases == ["2"])
        #expect(DatabaseManager.shared.session(for: connection.id)?.browseDatabase == "2")
    }

    @Test("A selection superseded while it waits never moves the connection")
    func supersededSelectionNeverSwitches() async throws {
        let (connection, recorder) = makeSession()
        defer { cleanUp(connection.id) }
        let coordinator = makeCoordinator(for: connection)
        defer { coordinator.teardown() }
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        coordinator.openTableTab("db2")
        await waitForQueuedCallers(1, on: connection.id)
        let superseded = coordinator.redisDatabaseSwitchTask

        coordinator.openTableTab("db3")
        await superseded?.value
        await waitForQueuedCallers(1, on: connection.id)

        release.open()
        try await holder.value
        await coordinator.redisDatabaseSwitchTask?.value

        #expect(recorder.switchedDatabases == ["3"])
        #expect(DatabaseManager.shared.session(for: connection.id)?.browseDatabase == "3")
    }

    /// Only a newer selection owns the tab's load. A selection that fails for any other reason,
    /// including one drained by a disconnect, has to give the load back or the tab keeps its spinner.
    @Test("A selection drained while it waits gives the tab's load back")
    func drainedSelectionDeclinesTheLoad() async throws {
        let (connection, recorder) = makeSession()
        defer { cleanUp(connection.id) }
        let coordinator = makeCoordinator(for: connection)
        defer { coordinator.teardown() }
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        coordinator.openTableTab("db2")
        await waitForQueuedCallers(1, on: connection.id)
        let superseded = coordinator.redisDatabaseSwitchTask
        coordinator.openTableTab("db3")
        await superseded?.value
        await waitForQueuedCallers(1, on: connection.id)
        #expect(coordinator.tabManager.selectedTab?.pagination.isLoading == true)

        DatabaseManager.shared.removeSession(for: connection.id)
        await coordinator.redisDatabaseSwitchTask?.value

        #expect(coordinator.tabManager.selectedTab?.pagination.isLoading == false)
        #expect(recorder.switchedDatabases.isEmpty)

        release.open()
        try await holder.value
    }

    /// A reconnect replaces the driver on the same session, so the session check alone cannot tell
    /// that the handle the selection was asked on is gone.
    @Test("A selection queued behind the driver switches the driver installed when its turn comes")
    func selectionSwitchesTheDriverInstalledWhenItRuns() async throws {
        let (connection, original) = makeSession()
        defer { cleanUp(connection.id) }
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        let selection = Task { @MainActor in
            try await DatabaseManager.shared.switchDatabase(to: "2", for: connection.id, persist: false)
        }
        await waitForQueuedCallers(1, on: connection.id)
        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 1)

        let replacement = RecordingRedisPluginDriver()
        DatabaseManager.shared.updateSession(connection.id) { session in
            session.driver = PluginDriverAdapter(connection: connection, pluginDriver: replacement)
        }
        release.open()
        try await holder.value
        try await selection.value

        #expect(replacement.switchedDatabases == ["2"])
        #expect(original.switchedDatabases.isEmpty)
    }

    @Test("A database the server refuses is reported on the tab the click retargeted")
    func refusedSelectionIsReportedOnTheTab() async throws {
        let (connection, recorder) = makeSession()
        defer { cleanUp(connection.id) }
        recorder.refuseSelections(with: RefusedSelection())
        let coordinator = makeCoordinator(for: connection)
        defer { coordinator.teardown() }

        coordinator.openTableTab("db3")
        await coordinator.redisDatabaseSwitchTask?.value

        let tab = try #require(coordinator.tabManager.selectedTab)
        #expect(tab.execution.errorMessage == RefusedSelection.message)
        #expect(tab.execution.errorQuery == nil)
        #expect(tab.execution.lastExecutedAt == nil)
        #expect(tab.pagination.isLoading == false)
        #expect(recorder.executedQueries.isEmpty)
        #expect(DatabaseManager.shared.session(for: connection.id)?.browseDatabase == "0")
    }

    /// Changing tab does not cancel the selection, so the answer has to find the tab it was for
    /// rather than whichever one is in front when the server replies.
    @Test("A refusal that arrives after a tab change lands on the retargeted tab")
    func refusalFindsItsOwnTab() async throws {
        let (connection, recorder) = makeSession()
        defer { cleanUp(connection.id) }
        recorder.refuseSelections(with: RefusedSelection())
        let coordinator = makeCoordinator(for: connection)
        defer { coordinator.teardown() }
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        coordinator.openTableTab("db3")
        await waitForQueuedCallers(1, on: connection.id)
        let retargetedTabId = try #require(coordinator.tabManager.selectedTabId)
        coordinator.tabManager.addTab(initialQuery: "PING")
        let frontTabId = try #require(coordinator.tabManager.selectedTabId)
        #expect(frontTabId != retargetedTabId)

        release.open()
        try await holder.value
        await coordinator.redisDatabaseSwitchTask?.value

        let retargeted = try #require(coordinator.tabManager.tabs.first { $0.id == retargetedTabId })
        let front = try #require(coordinator.tabManager.tabs.first { $0.id == frontTabId })
        #expect(retargeted.execution.errorMessage == RefusedSelection.message)
        #expect(front.execution.errorMessage == nil)
    }

    /// The session moved, but the query belongs to the retargeted tab, which loads when it is
    /// shown again. Running it on the tab in front would put another tab's query on this database.
    @Test("A selection that lands after a tab change does not run the front tab's query")
    func landedSelectionLeavesTheFrontTabAlone() async throws {
        let (connection, recorder) = makeSession()
        defer { cleanUp(connection.id) }
        let coordinator = makeCoordinator(for: connection)
        defer { coordinator.teardown() }
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        coordinator.openTableTab("db3")
        await waitForQueuedCallers(1, on: connection.id)
        let retargetedTabId = try #require(coordinator.tabManager.selectedTabId)
        coordinator.tabManager.addTab(initialQuery: "PING")

        release.open()
        try await holder.value
        await coordinator.redisDatabaseSwitchTask?.value

        let retargeted = try #require(coordinator.tabManager.tabs.first { $0.id == retargetedTabId })
        #expect(recorder.switchedDatabases == ["3"])
        #expect(recorder.executedQueries.allSatisfy { $0.hasPrefix("KEYTREE") })
        #expect(retargeted.pagination.isLoading == false)
    }

    @Test("Loading the key tree waits for the driver")
    func keyTreeLoadWaitsForTheDriver() async throws {
        let (connection, recorder) = makeSession()
        defer { cleanUp(connection.id) }
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        let viewModel = RedisKeyTreeViewModel()
        let load = viewModel.loadKeys(connectionId: connection.id, databaseIndex: 2, separator: ":")
        await waitForQueuedCallers(1, on: connection.id)

        #expect(DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) == 1)
        #expect(recorder.executedQueries.isEmpty)
        #expect(viewModel.state.erased == .loading)

        release.open()
        try await holder.value
        await load.value

        #expect(recorder.executedQueries == ["KEYTREE DB 2 LIMIT \(RedisKeyTreeViewModel.maxKeys)"])
        #expect(viewModel.state.value?.database == "2")
    }

    /// Query execution runs off the switch task, so the key's command lands a moment after it. The
    /// bound turns a command that never runs into a failed assertion rather than a hung suite.
    private func waitForExecution(of query: String, on recorder: RecordingRedisPluginDriver) async {
        for _ in 0..<500 where !recorder.executedQueries.contains(query) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("The key tree first lists the database the session was left on after connecting")
    func firstTreeLoadListsTheSessionDatabase() async throws {
        let (connection, recorder) = makeSession()
        defer { cleanUp(connection.id) }
        DatabaseManager.shared.updateSession(connection.id) { $0.browseDatabase = "5" }
        let coordinator = makeCoordinator(for: connection)
        defer { coordinator.teardown() }

        coordinator.initRedisKeyTreeIfNeeded()
        let listing = "KEYTREE DB 5 LIMIT \(RedisKeyTreeViewModel.maxKeys)"
        await waitForExecution(of: listing, on: recorder)

        #expect(recorder.executedQueries == [listing])
    }

    /// A Cluster serves database 0 only, so a saved index from a standalone setup is refused at
    /// connect and the session records no database. Listing that index fails the whole tree.
    @Test("With no database recorded for the session the key tree lists database 0")
    func firstTreeLoadWithoutASessionDatabaseListsZero() async throws {
        let (connection, recorder) = makeSession()
        defer { cleanUp(connection.id) }
        DatabaseManager.shared.updateSession(connection.id) { $0.browseDatabase = nil }
        let coordinator = makeCoordinator(for: connection)
        defer { coordinator.teardown() }
        coordinator.toolbarState.currentDatabase = "5"

        coordinator.initRedisKeyTreeIfNeeded()
        let listing = "KEYTREE DB 0 LIMIT \(RedisKeyTreeViewModel.maxKeys)"
        await waitForExecution(of: listing, on: recorder)

        #expect(recorder.executedQueries == [listing])
    }

    /// The key stays quoted even when it needs no quoting: left bare, the editor reads the `:x` in
    /// `five:x` as a query parameter, opens the parameter panel and runs nothing.
    @Test("Opening a key reads it in the key's database and leaves the session where it was")
    func openingAKeyLeavesTheSessionAlone() async throws {
        let (connection, recorder) = makeSession()
        defer { cleanUp(connection.id) }
        let coordinator = makeCoordinator(for: connection)
        defer { coordinator.teardown() }
        coordinator.toolbarState.currentDatabase = "2"

        coordinator.openRedisKey("five:x", keyType: "string", inDatabase: 5)
        let read = RedisKeyTreeCommand.openKey("five:x", keyType: "string", inDatabase: 5)
        await waitForExecution(of: read, on: recorder)

        #expect(read == #"DB 5 GET "five:x""#)
        #expect(recorder.events == ["execute:\(read)"])
        #expect(coordinator.redisDatabaseSwitchTask == nil)
        #expect(coordinator.toolbarState.currentDatabase == "2")
        #expect(DatabaseManager.shared.session(for: connection.id)?.browseDatabase == "0")
        #expect(coordinator.tabManager.selectedTab?.title == "five:x")
    }

    @Test("Opening a key while a database click waits leaves no tab loading")
    func keyOpenedBehindAPendingClickLeavesNoSpinner() async throws {
        let (connection, recorder) = makeSession()
        defer { cleanUp(connection.id) }
        let coordinator = makeCoordinator(for: connection)
        defer { coordinator.teardown() }
        let release = Latch()
        let holder = await holdDriver(connection.id, until: release)

        coordinator.openTableTab("db3")
        await waitForQueuedCallers(1, on: connection.id)
        let clickedTabId = try #require(coordinator.tabManager.selectedTabId)
        coordinator.openRedisKey("three:a", keyType: "hash", inDatabase: 3)

        release.open()
        try await holder.value
        await coordinator.redisDatabaseSwitchTask?.value
        let read = RedisKeyTreeCommand.openKey("three:a", keyType: "hash", inDatabase: 3)
        await waitForExecution(of: read, on: recorder)

        let clicked = try #require(coordinator.tabManager.tabs.first { $0.id == clickedTabId })
        #expect(clicked.pagination.isLoading == false)
        #expect(recorder.switchedDatabases == ["3"])
        #expect(recorder.executedQueries.contains(read))
    }
}

private struct RefusedSelection: LocalizedError {
    static let message = "ERR DB index is out of range"

    var errorDescription: String? { Self.message }
}

/// Records the calls that move or read the connection. The ping answers, because Redis declares a
/// health monitor and a check before use would otherwise fail the session.
private final class RecordingRedisPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var switched: [String] = []
    private var executed: [String] = []
    private var log: [String] = []
    private var selectionRefusal: Error?

    func refuseSelections(with error: Error) {
        lock.withLock { selectionRefusal = error }
    }

    var switchedDatabases: [String] {
        lock.withLock { switched }
    }

    var executedQueries: [String] {
        lock.withLock { executed }
    }

    /// Switches and executions in the order they reached the driver.
    var events: [String] {
        lock.withLock { log }
    }

    func ping() async throws {}

    func switchDatabase(to database: String) async throws {
        let refusal = lock.withLock { selectionRefusal }
        if let refusal { throw refusal }
        lock.withLock {
            switched.append(database)
            log.append("switch:\(database)")
        }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock {
            executed.append(query)
            log.append("execute:\(query)")
        }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func connect() async throws {}
    func disconnect() {}
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
}
