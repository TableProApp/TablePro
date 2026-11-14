import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct RunDiscardGuardTests {
    // A query tab showing a result with staged edits. `isShowingConfirmAlert` stands in for the discard prompt,
    // which answers false while it is up.
    private func makeEditedResult() -> (CoordinatorFixture, UUID) {
        let fixture = CoordinatorFixture()
        fixture.coordinator.executionGate = AlwaysAllowGate()
        let tab = fixture.addTab(QueryTab(title: "Query", query: "SELECT * FROM users", tabType: .query))
        let shown = ResultSet(label: "Result 1", tableRows: TableRows())
        fixture.tabManager.mutate(tabId: tab.id) { $0.display.replaceUnpinnedResults(with: [shown]) }
        fixture.changeManager.hasChanges = true
        fixture.coordinator.isShowingConfirmAlert = true
        return (fixture, tab.id)
    }

    @Test("Running a statement over staged edits asks before it replaces the result")
    func runStatementAsksFirst() {
        let (fixture, tabId) = makeEditedResult()

        #expect(!fixture.coordinator.runStatement("SELECT * FROM users", onTab: fixture.coordinator.commandTabId))

        #expect(fixture.changeManager.hasChanges)
        #expect(!fixture.coordinator.isShowingSafeModePrompt)
        #expect(!fixture.coordinator.tabExecution.isExecuting(tabId))
    }

    @Test("Run and Run All over staged edits ask before they replace the result")
    func runAndRunAllAskFirst() {
        let (fixture, tabId) = makeEditedResult()

        fixture.coordinator.runQuery(onTab: fixture.coordinator.commandTabId, viewport: .firstRow)
        fixture.coordinator.runAllStatements(onTab: fixture.coordinator.commandTabId)

        #expect(fixture.changeManager.hasChanges)
        #expect(!fixture.coordinator.isShowingSafeModePrompt)
        #expect(!fixture.coordinator.tabExecution.isExecuting(tabId))
    }

    @Test("A tab with no result runs without asking about another tab's edits")
    func tabWithoutAResultRunsAtOnce() {
        let fixture = CoordinatorFixture()
        fixture.coordinator.executionGate = AlwaysAllowGate()
        fixture.addTab(QueryTab(title: "Query", query: "SELECT 1", tabType: .query))
        fixture.changeManager.hasChanges = true
        fixture.coordinator.isShowingConfirmAlert = true

        #expect(fixture.coordinator.runStatement("SELECT 1", onTab: fixture.coordinator.commandTabId))
    }
}
