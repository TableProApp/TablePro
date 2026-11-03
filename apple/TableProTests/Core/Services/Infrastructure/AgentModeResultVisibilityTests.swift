import AppKit
import Foundation
@testable import TablePro
import Testing

// A selected tab's result is off screen while the window draws Agent mode, so it is marked; the
// mark has to go when the tab is on screen again, or it shows on the tab once the user moves off it.
@Suite("Agent mode result visibility", .serialized)
@MainActor
struct AgentModeResultVisibilityTests {
    @Test("A selected tab counts as selected while browsing, and not in Agent mode")
    func agentModeHidesTheSelectedTab() throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let coordinator = try harness.coordinator(of: harness.foreground)
        let tab = try harness.addSelectedTab(to: harness.foreground)
        let windowId = harness.registerWindow(for: coordinator)
        defer { WindowLifecycleMonitor.shared.unregisterWindow(for: windowId) }
        let owner = OperationOwner.tab(windowId: windowId, tabId: tab.id)

        let browsing = ResultVisibilityResolver.resolve(owner: owner, connectionId: coordinator.connectionId)
        #expect(browsing.ownerIsSelectedInWindow)

        harness.controller.setContentMode(.agent)
        let inAgentMode = ResultVisibilityResolver.resolve(owner: owner, connectionId: coordinator.connectionId)

        #expect(!inAgentMode.ownerIsSelectedInWindow)
        #expect(!inAgentMode.resultIsOnScreen)
    }

    @Test("A result that finishes in Agent mode marks the selected tab, and Browse clears it")
    func browseClearsTheMarkAgentModeLeft() throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let coordinator = try harness.coordinator(of: harness.foreground)
        let tab = try harness.addSelectedTab(to: harness.foreground)
        let windowId = harness.registerWindow(for: coordinator)
        defer { WindowLifecycleMonitor.shared.unregisterWindow(for: windowId) }
        harness.controller.setContentMode(.agent)

        let visibility = ResultVisibilityResolver.resolve(
            owner: .tab(windowId: windowId, tabId: tab.id),
            connectionId: coordinator.connectionId
        )
        let decision = OperationCompletionPolicy.decide(
            completion: OperationCompletion(
                kind: .query,
                owner: .tab(windowId: windowId, tabId: tab.id),
                connectionId: coordinator.connectionId,
                connectionName: coordinator.connection.name,
                databaseName: nil,
                elapsed: .seconds(60),
                outcome: .succeeded(OperationSummary(rowsAffected: 3))
            ),
            visibility: visibility,
            settings: NotificationSettings()
        )
        #expect(decision.marksOwnerUnseen)
        OperationUnseenMarker.mark(.tab(windowId: windowId, tabId: tab.id), outcome: .succeeded)
        #expect(unseenOutcome(of: tab.id, in: coordinator) == .succeeded)

        harness.controller.setContentMode(.browse)

        #expect(unseenOutcome(of: tab.id, in: coordinator) == nil)
    }

    @Test("Selecting a connection clears the mark a result left on its selected tab")
    func selectingTheConnectionClearsItsMark() throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let coordinator = try harness.coordinator(of: harness.background)
        let tab = try harness.addSelectedTab(to: harness.background)
        coordinator.tabManager.mutate(tabId: tab.id) { $0.execution.unseenOutcome = .failed }

        harness.controller.workspaces.select(harness.background.connectionId)

        #expect(unseenOutcome(of: tab.id, in: coordinator) == nil)
    }

    @Test("A mark on a tab that is not selected stays when the pane shows again")
    func unselectedTabKeepsItsMark() throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let coordinator = try harness.coordinator(of: harness.foreground)
        let marked = try harness.addSelectedTab(to: harness.foreground)
        try harness.addSelectedTab(to: harness.foreground)
        coordinator.tabManager.mutate(tabId: marked.id) { $0.execution.unseenOutcome = .succeeded }

        harness.controller.setContentMode(.agent)
        harness.controller.setContentMode(.browse)

        #expect(unseenOutcome(of: marked.id, in: coordinator) == .succeeded)
    }

    private func unseenOutcome(of tabId: UUID, in coordinator: MainContentCoordinator) -> TabUnseenOutcome? {
        coordinator.tabManager.tabs.first { $0.id == tabId }?.execution.unseenOutcome
    }
}
