//
//  TableAutoRefreshGateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TableAutoRefreshGateTests {
    @Test("A visible, idle, loaded table tab refreshes")
    func idleTabRefreshes() {
        #expect(TableAutoRefreshGate().decision == .refresh)
    }

    @Test("Each state that a reload would break waits, with its own reason")
    func eachPauseStateWaits() {
        let cases: [(String, (inout TableAutoRefreshGate) -> Void, TableAutoRefreshPause)] = [
            ("window hidden", { $0.windowIsVisible = false }, .notVisible),
            ("tab not selected", { $0.isSelectedInWindow = false }, .notVisible),
            ("disconnected", { $0.isConnected = false }, .disconnected),
            ("JSON mode", { $0.viewMode = .json }, .otherViewMode),
            ("structure mode", { $0.viewMode = .structure }, .otherViewMode),
            ("open transaction", { $0.holdsTransaction = true }, .openTransaction),
            ("unsaved edits", { $0.holdsUnsavedWork = true }, .unsavedChanges),
            ("sidebar staged drops", { $0.hasSidebarDataWork = true }, .unsavedChanges),
            ("open cell editor", { $0.isEditingCell = true }, .editing),
            ("grid popover or context menu", { $0.gridHoldsTransientUI = true }, .interacting),
            ("inspector pop-out window", { $0.inspectorHoldsValueWindow = true }, .valueWindowOpen),
            ("live scroll or drag", { $0.gridIsTrackingInteraction = true }, .interacting),
            ("running load", { $0.load = .busy }, .loading),
            ("pending count", { $0.isCountPending = true }, .loading),
            ("load more", { $0.isLoadingMore = true }, .loading),
            ("never loaded", { $0.hasLoaded = false }, .loading),
            ("Safe Mode prompt", { $0.showsSafeModePrompt = true }, .safeModePrompt),
            ("selection without a key", { gate in
                gate.hasSelection = true
                gate.hasPrimaryKey = false
            }, .unkeyedSelection),
        ]
        for (name, configure, pause) in cases {
            var gate = TableAutoRefreshGate()
            configure(&gate)
            #expect(gate.decision == .wait(pause), "\(name)")
        }
    }

    @Test("An open editor names the editor, not the unsaved work it also counts as")
    func editorWinsOverUnsavedWork() {
        var gate = TableAutoRefreshGate()
        gate.isEditingCell = true
        gate.holdsUnsavedWork = true
        #expect(gate.decision == .wait(.editing))
    }

    @Test("A selection in a keyed table still refreshes, since the key brings it back")
    func keyedSelectionRefreshes() {
        var gate = TableAutoRefreshGate()
        gate.hasSelection = true
        #expect(gate.decision == .refresh)
    }

    @Test("A failed tick and a tab that is no longer a table stop the schedule")
    func failureAndNonTableStop() {
        var failed = TableAutoRefreshGate()
        failed.previousTickFailed = true
        var query = TableAutoRefreshGate()
        query.isTableTab = false

        #expect(failed.decision == .stop)
        #expect(query.decision == .stop)
    }

    @Test("Only the pauses a reader can act on name themselves in the help")
    func pauseHelp() {
        #expect(TableAutoRefreshPause.unsavedChanges.help == "Auto Refresh waits while the table has unsaved changes.")
        #expect(TableAutoRefreshPause.disconnected.help == "Auto Refresh waits until the connection is back.")
        #expect(TableAutoRefreshPause.openTransaction.help == "Auto Refresh waits while a transaction is open.")
        #expect(TableAutoRefreshPause.valueWindowOpen.help == "Auto Refresh waits while a value is open in its own window.")
        #expect(TableAutoRefreshPause.notVisible.help == nil)
        #expect(TableAutoRefreshPause.interacting.help == nil)
    }
}
