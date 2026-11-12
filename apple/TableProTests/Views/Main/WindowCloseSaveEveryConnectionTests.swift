import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct WindowCloseSaveEveryConnectionTests {
    private func actions(
        for coordinator: MainContentCoordinator,
        in window: NSWindow,
        attach: Bool = true
    ) -> MainContentCommandActions {
        var selectedTables: Set<DatabaseTreeTableRef> = []
        var pendingTruncates: Set<DatabaseTreeTableRef> = []
        var pendingDeletes: Set<DatabaseTreeTableRef> = []
        var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]
        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: coordinator.connection,
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(
                get: { tableOperationOptions },
                set: { tableOperationOptions = $0 }
            ),
            trailingPaneState: TrailingPaneState()
        )
        actions.window = window
        if attach { coordinator.commandActions = actions }
        return actions
    }

    @Test("Save on a window close keeps the window while another connection holds edits only their tab can save")
    func saveKeepsTheWindowForAnotherConnectionsEdits() async throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let front = try harness.coordinator(of: harness.foreground)
        let back = try harness.coordinator(of: harness.background)
        let frontActions = actions(for: front, in: harness.window)
        let backActions = actions(for: back, in: harness.window)
        try harness.addSelectedTab(to: harness.foreground)
        try harness.addSelectedTab(to: harness.background)

        var edited = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        edited.pendingChanges.insertedRowIDs = [.inserted(UUID())]
        edited.pendingChanges.columns = ["id", "name"]
        edited.pendingChanges.primaryKeyColumns = ["id"]
        back.tabManager.tabs.append(edited)
        frontActions.confirmSaveChanges = { _, _ in .save }

        let outcome = await frontActions.closeWindowAwaiting()

        #expect(outcome == .cancelled)
        #expect(back.tabManager.tabs.contains { $0.id == edited.id })
        withExtendedLifetime(backActions) {}
    }

    // Its actions arrive only once its pane mounts, after Save has shown it.
    @Test("Save waits for a connection that has not shown its pane yet, then saves it and closes")
    func saveReachesAConnectionNotShownYet() async throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let front = try harness.coordinator(of: harness.foreground)
        let back = try harness.coordinator(of: harness.background)
        front.contentWindow = harness.window
        let frontActions = actions(for: front, in: harness.window)
        let backActions = actions(for: back, in: harness.window, attach: false)
        back.commandActions = nil
        try harness.addSelectedTab(to: harness.foreground)
        back.toolbarState.hasCreateTablePending = true
        frontActions.confirmSaveChanges = { _, _ in
            Task { @MainActor in back.commandActions = backActions }
            return .save
        }

        let outcome = await frontActions.closeWindowAwaiting()

        #expect(outcome == .closed)
    }

    @Test("A close cancelled while it waits for a connection's pane stops after that one wait and keeps the window")
    func cancelledCloseStopsWaiting() async throws {
        let harness = TwoConnectionWindow()
        defer { harness.tearDown() }
        let front = try harness.coordinator(of: harness.foreground)
        let back = try harness.coordinator(of: harness.background)
        front.contentWindow = harness.window
        let frontActions = actions(for: front, in: harness.window)
        back.commandActions = nil
        try harness.addSelectedTab(to: harness.foreground)
        back.toolbarState.hasCreateTablePending = true
        let clock = CountingClock()
        frontActions.paneWaitClock = clock
        frontActions.confirmSaveChanges = { _, _ in .save }

        let close = Task { await frontActions.closeWindowAwaiting() }
        await clock.firstSleep.wait()
        close.cancel()
        let outcome = await close.value

        #expect(outcome == .cancelled)
        #expect(clock.sleepCount == 1)
    }
}

// Time stands still, so a sleep ends only by cancellation; the first one opens a gate the test waits on.
private final class CountingClock: Clock, @unchecked Sendable {
    let firstSleep = AsyncGate()
    private let base = ManualClock()
    private let lock = NSLock()
    private var count = 0

    var sleepCount: Int { lock.withLock { count } }
    var now: ManualClock.Instant { base.now }
    var minimumResolution: Duration { base.minimumResolution }

    func sleep(until deadline: ManualClock.Instant, tolerance: Duration?) async throws {
        let isFirst = lock.withLock {
            count += 1
            return count == 1
        }
        if isFirst { await firstSleep.open() }
        try await base.sleep(until: deadline, tolerance: tolerance)
    }
}
