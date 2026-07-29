import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("ClearQueryResults")
struct ClearQueryResultsTests {
    @Test("Clearing results empties rows, result sets, and execution state")
    @MainActor
    func clearEmptiesResultsAndState() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(databaseName: "db")
        let tabId = try #require(coordinator.tabManager.selectedTab?.id)
        let index = try #require(coordinator.tabManager.selectedTabIndex)

        coordinator.setActiveTableRows(TestFixtures.makeTableRows(rowCount: 3), for: tabId)
        coordinator.tabManager.mutate(at: index) { tab in
            tab.execution.lastExecutedAt = Date()
            tab.execution.rowsAffected = 3
            tab.execution.executionTime = 0.12
            tab.display.activeResultSetId = UUID()
        }

        coordinator.clearActiveQueryResults()

        #expect(coordinator.tabSessionRegistry.tableRows(for: tabId).rows.isEmpty)
        let tab = try #require(coordinator.tabManager.selectedTab)
        #expect(tab.display.resultSets.isEmpty)
        #expect(tab.display.activeResultSetId == nil)
        #expect(tab.execution.lastExecutedAt == nil)
        #expect(tab.execution.rowsAffected == 0)
        #expect(tab.execution.executionTime == nil)
        #expect(tab.display.isResultsCollapsed)
    }

    @Test("Clearing results leaves the query text intact")
    @MainActor
    func clearKeepsQueryText() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db")
        let tabId = try #require(coordinator.tabManager.selectedTab?.id)
        coordinator.setActiveTableRows(TestFixtures.makeTableRows(rowCount: 2), for: tabId)

        coordinator.clearActiveQueryResults()

        #expect(coordinator.tabManager.selectedTab?.content.query == "SELECT 1")
    }

    @Test("Can clear only when a query tab has results")
    @MainActor
    func canClearGating() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(databaseName: "db")
        #expect(coordinator.canClearActiveQueryResults == false)

        let tabId = try #require(coordinator.tabManager.selectedTab?.id)
        coordinator.setActiveTableRows(TestFixtures.makeTableRows(rowCount: 1), for: tabId)
        #expect(coordinator.canClearActiveQueryResults == true)
    }

    @Test("Cannot clear results on a table tab")
    @MainActor
    func cannotClearOnTableTab() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        try coordinator.tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db")
        let tabId = try #require(coordinator.tabManager.selectedTab?.id)
        coordinator.setActiveTableRows(TestFixtures.makeTableRows(rowCount: 3), for: tabId)

        #expect(coordinator.canClearActiveQueryResults == false)
    }

    @MainActor
    private static func makeCoordinator() -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "db"),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }
}
