import Foundation
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
struct ScriptErrorResultTests {
    // The tab used to keep a copy of the message, which then sat over every other result of the run.
    @Test("A failed script keeps its error on the Error result, not over the results that succeeded")
    func failureStaysOnTheErrorResult() async throws {
        let connection = TestFixtures.makeConnection()
        let driver = MockDatabaseDriver(connection: connection)
        driver.failsStatementContaining = (
            "nope",
            NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "relation \"nope\" does not exist"])
        )
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        session.browseDatabase = connection.database
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer {
            coordinator.cancelAllQueryTasks()
            coordinator.teardown()
            DatabaseManager.shared.removeSession(for: connection.id)
        }
        let tab = QueryTab(title: "Query", query: "SELECT 1;\nSELECT * FROM nope;", tabType: .query)
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        coordinator.runAllStatements()
        try await waitUntil {
            !coordinator.tabExecution.isExecuting(tab.id)
                && tabManager.tabs.first?.display.resultSets.last?.errorMessage != nil
        }

        let settled = try #require(tabManager.tabs.first)
        let failed = try #require(settled.display.resultSets.last)
        #expect(settled.display.resultSets.count == 2)
        #expect(settled.execution.errorMessage == nil)
        #expect(failed.failedQuery?.contains("nope") == true)
        #expect(settled.shownError?.isDismissible == false)

        let first = try #require(settled.display.resultSets.first)
        tabManager.mutate(tabId: tab.id) { $0.display.activeResultSetId = first.id }
        let sibling = try #require(tabManager.tabs.first)
        #expect(sibling.shownError == nil)
        #expect(sibling.latestError?.message.contains("nope") == true)
    }
}
