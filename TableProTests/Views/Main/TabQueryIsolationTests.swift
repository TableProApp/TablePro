//
//  TabQueryIsolationTests.swift
//  TableProTests
//
//  Starting work in one tab must not end work in another. Cancellation used to be keyed by window
//  and connection and never by the tab that owned the work, so a Run, a table opened from the
//  sidebar, a Refresh, an Explain or a retarget each cancelled whatever the window held: a batch
//  running in another tab stopped at its next statement, rolled back, and reported "cancelled by
//  user" over a Stop nobody pressed.
//
//  Every case drives a real entry point rather than the ownership API underneath it, because the
//  defect was that five separate start paths each cancelled on their own terms.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Tab query isolation", .serialized)
@MainActor
struct TabQueryIsolationTests {
    /// Tab A holding a live execution: a claim, a never-ending task, and a driver registered under
    /// that execution's lease, which is the only thing a cancel can reach.
    private struct RunningTab {
        let tabId: UUID
        let claim: TabExecutionClaim
        let task: Task<Void, Never>
        let driver: CancelCountingDriver
    }

    // MARK: - Every start path in tab B

    @Test("Running a query in another tab leaves the first tab's batch alone")
    func runQueryLeavesTheOtherTabAlone() async {
        await withTwoTabs { coordinator, _, _ in
            coordinator.executeQueryInternal("SELECT 1")
        }
    }

    @Test("Running a parameterized query in another tab leaves the first tab's batch alone")
    func parameterizedQueryLeavesTheOtherTabAlone() async {
        await withTwoTabs { coordinator, _, _ in
            coordinator.queryExecutionCoordinator.executeQueryInternalParameterized(
                "SELECT ?",
                parameters: ["1"],
                originalParameters: []
            )
        }
    }

    @Test("Running several statements in another tab leaves the first tab's batch alone")
    func multiStatementRunLeavesTheOtherTabAlone() async {
        await withTwoTabs { coordinator, _, _ in
            coordinator.queryExecutionCoordinator.executeMultipleStatementsWithParameters(
                SQLStatementScanner.executableStatements(in: "SELECT 1; SELECT 2"),
                parameters: []
            )
        }
    }

    /// The variant is passed explicitly so the case cannot go quiet: without one, `runExplain`
    /// returns before it starts anything on a build where no driver plugin declared a variant.
    @Test("Explaining in another tab leaves the first tab's batch alone")
    func explainLeavesTheOtherTabAlone() async {
        await withTwoTabs { coordinator, _, _ in
            coordinator.runExplain(
                variant: ExplainVariant(id: "plain", label: "Explain", sqlPrefix: "EXPLAIN")
            )
        }
    }

    /// Refresh used to call the window-wide `cancelCurrentQuery`, which is how a table tab's Refresh
    /// rolled back an editor tab's batch.
    @Test("Refreshing a table tab leaves another tab's batch alone")
    func refreshLeavesTheOtherTabAlone() async {
        await withTwoTabs(selectedIsTable: true) { coordinator, _, _ in
            coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})
        }
    }

    /// Opening a table into the selected tab from the sidebar retargets it, and the retarget hook
    /// supersedes. That supersede reached the window's one handle, not the tab's.
    @Test("Retargeting a tab leaves another tab's batch alone")
    func retargetLeavesTheOtherTabAlone() async {
        await withTwoTabs(selectedIsTable: true, startsExecution: false) { coordinator, _, _ in
            _ = try? coordinator.tabManager.replaceTabContent(tableName: "orders", databaseName: "app")
        }
    }

    /// Closing tab B takes B's own handle down and nothing else. Before the change the close path
    /// had to check whether the window's handle happened to belong to the closing tab.
    @Test("Closing a tab leaves another tab's batch alone")
    func closingATabLeavesTheOtherTabAlone() async {
        await withTwoTabs(startsExecution: false) { coordinator, _, selected in
            guard let tab = coordinator.tabManager.tabs.first(where: { $0.id == selected }) else { return }
            coordinator.releaseExecution(of: tab)
        }
    }

    // MARK: - Stop

    @Test("Stop with another tab selected cancels that tab only")
    func stopActsOnTheSelectedTabOnly() {
        let harness = makeHarness()
        defer { harness.tearDown() }
        let running = harness.running
        let selectedLease = DriverLeaseOwner()
        let selectedDriver = CancelCountingDriver(connection: harness.connection)
        let selectedClaim = harness.coordinator.tabExecution.claim(harness.selectedTabId)
        let selectedTask = Self.neverEndingTask()
        harness.coordinator.installQueryTask(
            selectedTask, owner: .claim(selectedClaim), lease: selectedLease
        )
        harness.seed(selectedDriver, lease: selectedLease)

        harness.coordinator.paginationCoordinator.cancelCurrentQuery()

        #expect(selectedTask.isCancelled)
        #expect(selectedDriver.cancelCount == 1)
        #expect(harness.coordinator.tabExecution.isExecuting(harness.selectedTabId) == false)

        #expect(running.task.isCancelled == false)
        #expect(running.driver.cancelCount == 0)
        #expect(harness.coordinator.tabExecution.isCurrent(running.claim))
        running.task.cancel()
        selectedTask.cancel()
    }

    /// Stop spares a claim whose commit is already on the wire, exactly as the window-wide stop did.
    @Test("Stop on a tab whose commit is in flight keeps its claim")
    func stopSparesACommittingClaim() {
        let harness = makeHarness()
        defer { harness.tearDown() }
        let claim = harness.coordinator.tabExecution.claim(harness.selectedTabId)
        let entered = harness.coordinator.tabExecution.enterUninterruptiblePhase(claim)
        #expect(entered)

        harness.coordinator.paginationCoordinator.cancelCurrentQuery()

        #expect(harness.coordinator.tabExecution.isCurrent(claim))
        let settled = harness.coordinator.tabExecution.settle(claim)
        #expect(settled)
        harness.running.task.cancel()
    }

    // MARK: - Window chrome follows the selected tab

    @Test("A background tab's work does not make the selected tab look busy")
    func busyStateFollowsTheSelectedTab() {
        let harness = makeHarness()
        defer { harness.tearDown() }

        #expect(harness.coordinator.tabExecution.isAnyExecuting)
        #expect(harness.coordinator.isSelectedTabBusy == false)
        #expect(harness.coordinator.isSelectedTabStoppable == false)

        harness.coordinator.tabManager.selectedTabId = harness.running.tabId
        #expect(harness.coordinator.isSelectedTabBusy)
        #expect(harness.coordinator.isSelectedTabStoppable)
        harness.running.task.cancel()
    }

    /// A completion retires its own tab's handle. The window-wide handle made this a live question:
    /// tab A's completion nilled whatever tab B had installed.
    @Test("A completion on one tab leaves another tab's handle installed")
    func completionRetiresOnlyItsOwnTab() {
        let harness = makeHarness()
        defer { harness.tearDown() }
        let selectedClaim = harness.coordinator.tabExecution.claim(harness.selectedTabId)
        let selectedTask = Self.neverEndingTask()
        harness.coordinator.installQueryTask(
            selectedTask, owner: .claim(selectedClaim), lease: DriverLeaseOwner()
        )

        let settled = harness.coordinator.tabExecution.settle(harness.running.claim)
        #expect(settled)
        harness.coordinator.retireQueryTask(.claim(harness.running.claim))

        #expect(harness.coordinator.queryTasks.hasTask(for: harness.running.tabId) == false)
        #expect(harness.coordinator.queryTasks.hasTask(for: harness.selectedTabId))
        harness.running.task.cancel()
        selectedTask.cancel()
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let coordinator: MainContentCoordinator
        let connection: DatabaseConnection
        let running: RunningTab
        let selectedTabId: UUID

        func seed(_ driver: CancelCountingDriver, lease: DriverLeaseOwner) {
            DatabaseManager.shared.runningDrivers[connection.id, default: [:]][UUID()] =
                RunningDriver(driver: driver, policy: .cancellableRead(lease))
        }

        func tearDown() {
            running.task.cancel()
            DatabaseManager.shared.runningDrivers.removeValue(forKey: connection.id)
            DatabaseManager.shared.removeSession(for: connection.id)
        }
    }

    /// Drives one start path in the selected tab and checks that the other tab's execution, task and
    /// driver are all untouched by it.
    private func withTwoTabs(
        selectedIsTable: Bool = false,
        startsExecution: Bool = true,
        _ start: (MainContentCoordinator, RunningTab, UUID) -> Void
    ) async {
        let harness = makeHarness(selectedIsTable: selectedIsTable)
        defer { harness.tearDown() }
        let running = harness.running

        start(harness.coordinator, running, harness.selectedTabId)

        /// Without this the case could pass by doing nothing at all, which is what a start path that
        /// silently returns early looks like from the other tab.
        #expect(harness.coordinator.tabExecution.isBusy(harness.selectedTabId) == startsExecution)

        #expect(running.task.isCancelled == false)
        #expect(harness.coordinator.tabExecution.isCurrent(running.claim))
        #expect(harness.coordinator.queryTasks.hasTask(for: running.tabId))
        /// A background cancel lands on a global queue, so the count is only meaningful once one
        /// could have arrived. Without the wait this arm would pass on a delivery that was merely
        /// slow rather than absent.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(running.driver.cancelCount == 0)
        harness.coordinator.cancelAllQueryTasks()
    }

    private func makeHarness(selectedIsTable: Bool = false) -> Harness {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(
            connection: connection,
            driver: MockDatabaseDriver(connection: connection)
        )
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )

        let runningTabId = Self.addTab(to: tabManager, title: "Batch", isTable: false)
        let selectedTabId = Self.addTab(to: tabManager, title: "Other", isTable: selectedIsTable)
        tabManager.selectedTabId = selectedTabId

        let claim = coordinator.tabExecution.claim(runningTabId)
        let lease = DriverLeaseOwner()
        let driver = CancelCountingDriver(connection: connection)
        let task = Self.neverEndingTask()
        coordinator.installQueryTask(task, owner: .claim(claim), lease: lease)
        DatabaseManager.shared.runningDrivers[connection.id, default: [:]][UUID()] =
            RunningDriver(driver: driver, policy: .cancellableRead(lease))

        return Harness(
            coordinator: coordinator,
            connection: connection,
            running: RunningTab(tabId: runningTabId, claim: claim, task: task, driver: driver),
            selectedTabId: selectedTabId
        )
    }

    private static func addTab(to tabManager: QueryTabManager, title: String, isTable: Bool) -> UUID {
        var tab = QueryTab(
            title: title,
            query: isTable ? "SELECT * FROM users" : "SELECT 1",
            tabType: isTable ? .table : .query,
            tableName: isTable ? "users" : nil
        )
        tab.tableContext.isEditable = isTable
        tab.execution.lastExecutedAt = isTable ? Date() : nil
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab.id
    }

    private static func neverEndingTask() -> Task<Void, Never> {
        Task { _ = try? await Task.sleep(for: .seconds(60)) }
    }
}

/// Counts `cancelQuery()` under a lock, because a background delivery runs off the main actor.
private final class CancelCountingDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected

    private let lock = NSLock()
    private var calls = 0

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func cancelQuery() throws {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func applyQueryTimeout(_ seconds: Int) async throws {}
    func execute(query: String) async throws -> QueryResult { Self.emptyResult }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult { Self.emptyResult }
    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        Self.emptyResult
    }

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
