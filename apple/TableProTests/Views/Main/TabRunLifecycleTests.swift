//
//  TabRunLifecycleTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import TableProTestSupport
import Testing

@MainActor
struct TabRunLifecycleTests {
    private let connection: DatabaseConnection
    private let storage: QueryHistoryStorage
    private let fixture: CoordinatorFixture
    private let driver: MockDatabaseDriver

    init() {
        let connection = TestFixtures.makeConnection(database: "app")
        let storage = QueryHistoryStorage(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tablepro-tests")
                .appendingPathComponent("tab_run_\(UUID().uuidString).db"),
            removeDatabaseOnDeinit: true
        )
        self.connection = connection
        self.storage = storage
        driver = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = "app"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        fixture = CoordinatorFixture(
            connection: connection,
            services: .live.recordingHistory(in: QueryHistoryManager(storage: storage, isCapturePaused: { false }))
        )
        fixture.coordinator.executionGate = AlwaysAllowGate()
    }

    private func tearDown() {
        fixture.coordinator.cancelAllQueryTasks()
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private func queryTab(_ query: String, select: Bool = true) -> QueryTab {
        var tab = QueryTab(title: "Query", query: query, tabType: .query)
        tab.tableContext.databaseName = "app"
        tab.tableContext.schemaName = "sales"
        return fixture.addTab(tab, select: select)
    }

    private func tableTab(_ name: String, select: Bool) -> QueryTab {
        var tab = QueryTab(title: name, query: "SELECT * FROM \(name)", tabType: .table, tableName: name)
        tab.tableContext.databaseName = "app"
        return fixture.addTab(tab, select: select)
    }

    @Test("Every statement of a script is filed in history under the tab's schema, like a single statement")
    func statementRunHistoryCarriesTheSchema() async throws {
        defer { tearDown() }
        let script = "INSERT INTO t VALUES (1);\nINSERT INTO t VALUES (2);"
        let tab = queryTab(script)
        let statements = SQLStatementScanner.executableStatements(in: script, grammar: fixture.coordinator.lexicalGrammar)

        fixture.coordinator.queryExecutionCoordinator.executeMultipleStatements(statements, onTab: tab.id)
        await fixture.coordinator.queryTasks.task(for: tab.id)?.value

        let scope = QueryHistoryScope.connection(connection.id)
        try await waitUntil { await storage.count(scope: scope) == 2 }
        let entries = await storage.fetch(QueryHistoryFilter(scope: scope), after: nil, limit: 3).entries
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.schemaName == "sales" && $0.databaseName == "app" })
    }

    @Test("Run All saves the tab list the way Run does")
    func runAllSavesTheTabList() {
        defer { tearDown() }
        let tab = queryTab("SELECT 1;\nSELECT 2;")
        let before = fixture.tabManager.tabStructureVersion

        fixture.coordinator.runAllStatements(onTab: tab.id)

        #expect(fixture.tabManager.tabStructureVersion == before + 1)
    }

    @Test("A result that lands in a background tab leaves the window's results toggle alone")
    func backgroundResultLeavesTheToolbarAlone() {
        defer { tearDown() }
        let background = queryTab("SELECT 1", select: false)
        fixture.tabManager.mutate(tabId: background.id) { $0.display.isResultsCollapsed = true }
        _ = queryTab("SELECT 2")
        fixture.coordinator.toolbarState.isResultsCollapsed = true

        fixture.coordinator.queryExecutionCoordinator.presentMultiStatementResults(
            tabId: background.id,
            timing: PluginQueryTiming(total: 0.1),
            totalRowsAffected: 1,
            newResultSets: [ResultSet(label: "Result 1", tableRows: TableRows())],
            sessionNotice: nil
        )

        #expect(fixture.coordinator.toolbarState.isResultsCollapsed)
        #expect(fixture.tabManager.tabs.first { $0.id == background.id }?.display.isResultsCollapsed == false)
    }

    @Test("Run names its tab: a query tab the editor is not showing is refused")
    func runRefusesAQueryTabTheEditorIsNotShowing() {
        defer { tearDown() }
        let hidden = queryTab("SELECT 1", select: false)
        let shown = queryTab("SELECT 2")

        fixture.coordinator.runQuery(onTab: hidden.id, viewport: .firstRow)
        #expect(fixture.coordinator.runStatement("SELECT 1", onTab: hidden.id) == false)

        #expect(!fixture.coordinator.tabExecution.isExecuting(hidden.id))
        #expect(!fixture.coordinator.tabExecution.isExecuting(shown.id))
        #expect(fixture.tabManager.selectedTabId == shown.id)
    }

    @Test("A reload of a background table tab runs that tab, not the selected one")
    func tableReloadRunsTheTabItNames() {
        defer { tearDown() }
        let background = tableTab("orders", select: false)
        let shown = tableTab("customers", select: true)

        fixture.coordinator.runQuery(onTab: background.id, viewport: .keepPlace)

        #expect(fixture.coordinator.tabExecution.isExecuting(background.id))
        #expect(!fixture.coordinator.tabExecution.isExecuting(shown.id))
    }

    @Test("A script still running when its window closes unwinds without reaching a released coordinator")
    func statementRunOutlivesItsWindow() async throws {
        defer { tearDown() }
        let gate = AsyncGate()
        driver.executeGate = gate
        let tabManager = QueryTabManager()
        var coordinator: MainContentCoordinator? = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            toolbarState: ConnectionToolbarState()
        )
        let script = "INSERT INTO t VALUES (1);\nINSERT INTO t VALUES (2);"
        let tab = QueryTab(title: "Query", query: script, tabType: .query)
        tabManager.tabs = [tab]
        tabManager.selectedTabId = tab.id
        let statements = SQLStatementScanner.executableStatements(in: script, grammar: try #require(coordinator).lexicalGrammar)
        try #require(coordinator).queryExecutionCoordinator.executeMultipleStatements(statements, onTab: tab.id)
        let handle = try #require(coordinator?.queryTasks.task(for: tab.id))
        await gate.arrived(1)

        coordinator?.teardown()
        coordinator = nil
        await gate.open()
        await handle.value
    }
}
