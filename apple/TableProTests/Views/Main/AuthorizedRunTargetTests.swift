import Foundation
import TableProPluginKit
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
struct AuthorizedRunTargetTests {
    private func errorMessage(of tabId: UUID, in fixture: CoordinatorFixture) -> String? {
        fixture.tabManager.tabs.first { $0.id == tabId }?.execution.errorMessage
    }

    @Test("A run approved after a tab switch stays on the tab that asked for it")
    func approvedRunStaysOnItsTab() async throws {
        let fixture = CoordinatorFixture()
        let gate = HeldExecutionGate()
        fixture.coordinator.executionGate = gate
        let asking = fixture.addTab(QueryTab(title: "A", query: "DELETE FROM orders", tabType: .query))
        let other = fixture.addTab(QueryTab(title: "B", query: "SELECT 1", tabType: .query), select: false)

        #expect(fixture.coordinator.runStatement("DELETE FROM orders"))
        try await waitUntil { gate.askedCount == 1 }
        fixture.tabManager.selectedTabId = other.id
        await gate.answer(allowing: true)

        // No session is injected, so the run ends in an error on whichever tab it ran on.
        try await waitUntil {
            self.errorMessage(of: asking.id, in: fixture) != nil || self.errorMessage(of: other.id, in: fixture) != nil
        }
        #expect(errorMessage(of: asking.id, in: fixture) != nil)
        #expect(errorMessage(of: other.id, in: fixture) == nil)
        #expect(!fixture.coordinator.tabExecution.isExecuting(other.id))
    }

    @Test("A run is dropped when its tab moved to another database before the approval")
    func approvedRunIsDroppedWhenTheScopeChanged() async throws {
        let fixture = CoordinatorFixture()
        let gate = HeldExecutionGate()
        fixture.coordinator.executionGate = gate
        let asking = fixture.addTab(QueryTab(title: "A", query: "DELETE FROM orders", tabType: .query))
        fixture.tabManager.mutate(tabId: asking.id) { $0.tableContext.databaseName = "staging" }

        #expect(fixture.coordinator.runStatement("DELETE FROM orders"))
        try await waitUntil { gate.askedCount == 1 }
        fixture.tabManager.mutate(tabId: asking.id) { $0.tableContext.databaseName = "production" }
        await gate.answer(allowing: true)
        try await waitUntil { !fixture.coordinator.isShowingSafeModePrompt }

        #expect(!fixture.coordinator.tabExecution.isExecuting(asking.id))
        #expect(errorMessage(of: asking.id, in: fixture)?.contains("moved to another database") == true)
        #expect(fixture.tabManager.tabs.first { $0.id == asking.id }?.execution.lastExecutedAt == nil)
    }

    @Test("A refusal lands on the tab that asked, wherever the selection went")
    func refusalLandsOnTheAskingTab() async throws {
        let fixture = CoordinatorFixture()
        let gate = HeldExecutionGate()
        fixture.coordinator.executionGate = gate
        let asking = fixture.addTab(QueryTab(title: "A", query: "DELETE FROM orders", tabType: .query))
        let other = fixture.addTab(QueryTab(title: "B", query: "SELECT 1", tabType: .query), select: false)

        #expect(fixture.coordinator.runStatement("DELETE FROM orders"))
        try await waitUntil { gate.askedCount == 1 }
        fixture.tabManager.selectedTabId = other.id
        fixture.tabManager.tabs.swapAt(0, 1)
        await gate.answer(allowing: false)
        try await waitUntil { !fixture.coordinator.isShowingSafeModePrompt }

        #expect(errorMessage(of: asking.id, in: fixture) == "Refused by the test")
        #expect(errorMessage(of: other.id, in: fixture) == nil)
    }
}
