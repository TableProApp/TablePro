//
//  MainContentCoordinatorAutoRefreshTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct MainContentCoordinatorAutoRefreshTests {
    @Test("A tick re-reads the selected table tab and writes no history row")
    func tickRereadsWithoutHistory() async throws {
        let harness = AutoRefreshHarness()
        defer { harness.tearDown() }

        await harness.tickOnce()

        #expect(harness.tableReads == 1)
        let tab = try #require(harness.tab)
        #expect(tab.execution.errorMessage == nil)
        #expect(tab.autoRefreshInterval == .fiveSeconds)
        await harness.expectOnlyTheMarkerIsRecorded()
    }

    @Test("A manual load records its row, so the marker check would see a tick's")
    func manualLoadRecordsHistory() async throws {
        let harness = AutoRefreshHarness()
        defer { harness.tearDown() }

        harness.coordinator.executeTableTabQueryDirectly(viewport: .keepPlace)
        await harness.coordinator.queryTasks.task(for: harness.tabId)?.value
        await harness.recordMarker()

        #expect(harness.recordAttempts == 2)
        try await waitUntil { await harness.historyCount == 2 }
    }

    @Test("A tick keeps the derived count rather than counting again")
    func tickKeepsTheCount() async throws {
        let harness = AutoRefreshHarness()
        defer { harness.tearDown() }
        harness.coordinator.tabManager.mutate(tabId: harness.tabId) { tab in
            tab.pagination.applyDerivedRowCount(42, isApproximate: false)
        }

        await harness.tickOnce()

        let tab = try #require(harness.tab)
        #expect(harness.tableReads == 1)
        #expect(tab.pagination.totalRowCount == 42)
        #expect(!tab.pagination.isCountPending)
    }

    @Test("An open cell editor holds the tick: no query, no commit, and the bar says why")
    func openEditorPausesWithoutCommitting() async throws {
        let harness = AutoRefreshHarness()
        defer { harness.tearDown() }
        let model = harness.coordinator.gridModel(forTab: harness.tabId)
        let mount = DataTabGridMountStub()
        mount.isEditing = true
        model.attach(mount)

        await harness.tickOnce()

        #expect(harness.tableReads == 0)
        #expect(mount.commitCount == 0)
        #expect(harness.tab?.autoRefreshPause == .editing)
        #expect(harness.tab?.autoRefreshInterval == .fiveSeconds)
        withExtendedLifetime(mount) {}
    }

    @Test("An editable inspector pop-out holds the tick until its window goes")
    func inspectorPopOutPauses() async {
        let harness = AutoRefreshHarness()
        defer { harness.tearDown() }
        let paneState = TrailingPaneState()
        harness.coordinator.trailingPaneState = paneState
        var popOut: JSONViewerWindowController? = JSONViewerWindowController()
        if let popOut { InspectorPopOutRegistry.record(popOut, openedFrom: paneState) }

        await harness.tickOnce()

        #expect(harness.tableReads == 0)
        #expect(harness.tab?.autoRefreshPause == .valueWindowOpen)

        popOut = nil
        #expect(!harness.coordinator.autoRefreshGate(forTab: harness.tabId).inspectorHoldsValueWindow)
        withExtendedLifetime(paneState) {}
    }

    @Test("A tick waits while the tab's database holds an open transaction")
    func openTransactionPauses() async throws {
        let harness = AutoRefreshHarness()
        defer { harness.tearDown() }
        let tracker = DatabaseManager.shared.sessionTransactions
        let key = SessionTransactionTracker.Key(connectionId: harness.connection.id, lane: nil)
        tracker.record(.inTransaction, on: harness.driver, for: key)
        defer { tracker.record(.idle, on: harness.driver, for: key) }

        await harness.tickOnce()

        #expect(harness.tableReads == 0)
        #expect(harness.tab?.autoRefreshPause == .openTransaction)
    }

    @Test("A disconnected session runs nothing and waits for the connection")
    func disconnectedSessionWaits() async throws {
        let harness = AutoRefreshHarness(status: .disconnected)
        defer { harness.tearDown() }

        await harness.tickOnce()

        #expect(harness.tableReads == 0)
        #expect(harness.tab?.autoRefreshPause == .disconnected)
    }

    @Test("A failed tick turns Auto Refresh off and leaves the tab's error on screen")
    func failedTickStops() async throws {
        let harness = AutoRefreshHarness()
        defer { harness.tearDown() }
        harness.driver.failReads()

        harness.start()
        await harness.clock.waitUntilSleeping()
        harness.clock.advance(by: .seconds(5))
        try await waitUntil { harness.tab?.autoRefreshInterval == .off }

        #expect(harness.tab?.execution.errorMessage != nil)
        #expect(harness.clock.pendingSleeperCount == 0)
        await harness.expectOnlyTheMarkerIsRecorded()
    }

    @Test("A tab that is not selected never ticks")
    func backgroundTabNeverRuns() async throws {
        let harness = AutoRefreshHarness()
        defer { harness.tearDown() }
        harness.coordinator.observeSelectionForAutoRefresh()
        harness.start()
        await harness.clock.waitUntilSleeping()

        let other = QueryTab(title: "Query", query: "SELECT 1", tabType: .query)
        harness.coordinator.tabManager.tabs.append(other)
        harness.coordinator.tabManager.selectedTabId = other.id
        try await waitUntil { !harness.coordinator.autoRefresh.isRunning }
        harness.clock.advance(by: .seconds(5))

        #expect(harness.tableReads == 0)
        #expect(harness.clock.pendingSleeperCount == 0)
    }
}

// MARK: - Harness

@MainActor
private final class AutoRefreshHarness {
    let connection: DatabaseConnection
    let driver: AutoRefreshDriver
    let coordinator: MainContentCoordinator
    let clock = ManualClock()
    let tabId: UUID
    private let history: QueryHistoryManager
    private let attempts: RecordAttemptCounter

    init(status: ConnectionStatus = .connected) {
        connection = DatabaseConnection(name: "Auto Refresh", database: "app", type: .postgresql)
        driver = AutoRefreshDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = status
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-refresh-\(UUID().uuidString).db")
        // Asked once per write, first thing, on the task that records it.
        let attempts = RecordAttemptCounter()
        self.attempts = attempts
        history = QueryHistoryManager(
            storage: QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true),
            isCapturePaused: {
                attempts.increment()
                return false
            }
        )
        coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState(),
            services: AppServices.live.replacingQueryHistory(history)
        )
        coordinator.executionGate = AlwaysAllowGate()
        coordinator.autoRefresh.clock = clock
        coordinator.autoRefresh.visibility = { _, _ in .onScreen }

        var tab = QueryTab(title: "jobs", query: "SELECT * FROM jobs LIMIT 1000", tabType: .table, tableName: "jobs")
        tab.tableContext.primaryKeyColumns = ["id"]
        tab.execution.lastExecutedAt = Date()
        coordinator.tabManager.tabs.append(tab)
        coordinator.tabManager.selectedTabId = tab.id
        tabId = tab.id
        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [[.text("1"), .text("first")]],
                columns: ["id", "name"],
                columnTypes: [.text(rawType: "INTEGER"), .text(rawType: "TEXT")]
            ),
            for: tab.id
        )
    }

    var tab: QueryTab? {
        coordinator.tabManager.tabs.first { $0.id == tabId }
    }

    var tableReads: Int {
        driver.sentStatements.filter { $0.contains("jobs") }.count
    }

    var historyCount: Int {
        get async { await history.count(scope: .connection(connection.id)) }
    }

    var recordAttempts: Int { attempts.value }

    // Through the same manager and store after the load, so a row the load recorded is written before it.
    func recordMarker() async {
        await history.record(QueryHistoryRecordRequest(
            query: "SELECT 'marker'",
            connectionId: connection.id,
            databaseName: connection.database,
            databaseType: connection.type,
            source: .editor,
            executionTime: 0,
            rowCount: 0,
            wasSuccessful: true
        ))
    }

    func expectOnlyTheMarkerIsRecorded(sourceLocation: SourceLocation = #_sourceLocation) async {
        await recordMarker()
        #expect(recordAttempts == 1, "the tick asked to record \(recordAttempts - 1) rows", sourceLocation: sourceLocation)
        #expect(await historyCount == 1, sourceLocation: sourceLocation)
    }

    func start() {
        coordinator.setAutoRefreshInterval(.fiveSeconds, forTab: tabId)
    }

    // One interval passes, and the schedule is back to waiting once the tick it ran has settled.
    func tickOnce() async {
        start()
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(5))
        await clock.waitUntilSleeping()
    }

    func tearDown() {
        coordinator.stopAutoRefresh()
        coordinator.cancelAllQueryTasks()
        DatabaseManager.shared.removeSession(for: connection.id)
        coordinator.teardown()
    }
}

private final class RecordAttemptCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { count.withLock { $0 } }

    func increment() {
        count.withLock { $0 += 1 }
    }
}

private struct AutoRefreshReadFailure: LocalizedError {
    var errorDescription: String? { "relation \"jobs\" does not exist" }
}

private final class AutoRefreshDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    private let lock = NSLock()
    private var statements: [String] = []
    private var fails = false

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    var sentStatements: [String] {
        lock.withLock { statements }
    }

    func failReads() {
        lock.withLock { fails = true }
    }

    private func answer(_ query: String) throws -> QueryResult {
        let failing = lock.withLock { () -> Bool in
            statements.append(query)
            return fails && query.contains("jobs")
        }
        if failing { throw AutoRefreshReadFailure() }
        return ScriptAnsweringDriver.resultSet(columns: ["id", "name"], rows: [["1", "first"], ["2", "second"]])
    }

    func execute(query: String) async throws -> QueryResult { try answer(query) }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult { try answer(query) }
    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        try answer(query)
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func ping() async throws {}
    func cancelQuery() throws {}
    func applyQueryTimeout(_ seconds: Int) async throws {}

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
}

@MainActor
private extension AppServices {
    func replacingQueryHistory(_ manager: QueryHistoryManager) -> AppServices {
        AppServices(
            appEvents: appEvents,
            appSettings: appSettings,
            appSettingsStorage: appSettingsStorage,
            connectionStorage: connectionStorage,
            databaseManager: databaseManager,
            pluginManager: pluginManager,
            schemaService: schemaService,
            schemaRefreshService: schemaRefreshService,
            schemaProviderRegistry: schemaProviderRegistry,
            catalogChangeService: catalogChangeService,
            sqlFavoriteManager: sqlFavoriteManager,
            favoriteTablesStorage: favoriteTablesStorage,
            favoriteDatabasesStorage: favoriteDatabasesStorage,
            tableFolderStorage: tableFolderStorage,
            aiChatStorage: aiChatStorage,
            aiKeyStorage: aiKeyStorage,
            aiAccessApprovals: aiAccessApprovals,
            groupStorage: groupStorage,
            tagStorage: tagStorage,
            sshProfileStorage: sshProfileStorage,
            credentialProfileStorage: credentialProfileStorage,
            featureAccess: featureAccess,
            syncMetadataStorage: syncMetadataStorage,
            favoritesExpansionState: favoritesExpansionState,
            linkedFolderWatcher: linkedFolderWatcher,
            queryHistoryManager: manager,
            dateFormattingService: dateFormattingService,
            copilotService: copilotService,
            mcpServerManager: mcpServerManager,
            syncTracker: syncTracker,
            welcomeRouter: welcomeRouter,
            telemetry: telemetry
        )
    }
}
