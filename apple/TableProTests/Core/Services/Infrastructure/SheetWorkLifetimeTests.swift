import AppKit
import Foundation
@testable import TablePro
import Testing

// A connection switch and an Agent mode toggle unparent the pane that presents the export and
// transfer sheets, so an `onDisappear` stop would end work nobody cancelled.
@Suite("Sheet work lifetime", .serialized)
@MainActor
struct SheetWorkLifetimeTests {
    @Test("Switching connection and back keeps what a sheet started running")
    func connectionSwitchKeepsSheetWork() throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let coordinator = try harness.coordinator(of: harness.foreground)
        var stopped = false
        _ = coordinator.sheetWork.begin { stopped = true }

        harness.controller.workspaces.select(harness.background.connectionId)
        #expect(harness.controller.detailPaneHost.shown === harness.background.panes.detail)
        harness.controller.workspaces.select(harness.foreground.connectionId)

        #expect(!stopped)
        #expect(!coordinator.sheetWork.isEmpty)
    }

    @Test("Agent mode and back keeps what a sheet started running")
    func agentModeToggleKeepsSheetWork() throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let coordinator = try harness.coordinator(of: harness.foreground)
        var stopped = false
        _ = coordinator.sheetWork.begin { stopped = true }

        harness.controller.setContentMode(.agent)
        #expect(harness.controller.detailPaneHost.shown === harness.foreground.panes.agentConversation)
        harness.controller.setContentMode(.browse)

        #expect(!stopped)
    }

    @Test("Closing the connection's workspace stops what its sheets started")
    func workspaceTeardownStopsSheetWork() throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let coordinator = try harness.coordinator(of: harness.background)
        var stopped = false
        _ = coordinator.sheetWork.begin { stopped = true }

        harness.background.teardown()

        #expect(stopped)
    }

    @Test("A session that ends tears its coordinator down and stops what its sheets started")
    func sessionEndStopsSheetWork() throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let coordinator = try harness.coordinator(of: harness.background)
        var stopped = false
        _ = coordinator.sheetWork.begin { stopped = true }

        DatabaseManager.shared.removeSession(for: harness.background.connectionId)
        harness.controller.refreshFromActiveSessions()

        #expect(harness.background.sessionState == nil)
        #expect(stopped)
    }
}
