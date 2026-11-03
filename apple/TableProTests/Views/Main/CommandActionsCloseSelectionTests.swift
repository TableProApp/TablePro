//
//  CommandActionsCloseSelectionTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct CommandActionsCloseSelectionTests {
    private struct Harness {
        let actions: MainContentCommandActions
        let coordinator: MainContentCoordinator
        let window: NSWindow
    }

    private func makeHarness() -> Harness {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let state = SessionStateFactory.create(connection: connection, payload: nil)
        let coordinator = state.coordinator

        var selectedTables: Set<DatabaseTreeTableRef> = []
        var pendingTruncates: Set<DatabaseTreeTableRef> = []
        var pendingDeletes: Set<DatabaseTreeTableRef> = []
        var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]

        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(
                get: { tableOperationOptions },
                set: { tableOperationOptions = $0 }
            ),
            trailingPaneState: TrailingPaneState()
        )

        let window = NSWindow()
        window.isReleasedWhenClosed = false
        coordinator.contentWindow = window
        actions.window = window
        return Harness(actions: actions, coordinator: coordinator, window: window)
    }

    // Emptied, so no close here files an entry in the runner's Recently Closed Tabs history.
    private func openTabs(in harness: Harness) throws -> (first: UUID, dirty: UUID, last: UUID) {
        let manager = harness.coordinator.tabManager
        for title in ["First", "Dirty", "Last"] {
            manager.addTab(title: title)
        }
        let dirtyIndex = try #require(manager.tabs.firstIndex { $0.title == "Dirty" })
        manager.tabs[dirtyIndex].content.sourceFileURL = URL(fileURLWithPath: "/private/tmp/close-selection.sql")
        manager.tabs[dirtyIndex].content.savedFileContent = "SELECT 1"
        manager.tabs[dirtyIndex].content.query = ""
        try #require(manager.tabs.allSatisfy { !$0.isReopenCandidate })
        try #require(harness.coordinator.hasUnsavedWork(in: manager.tabs[dirtyIndex]))
        let first = try #require(manager.tabs.first { $0.title == "First" }?.id)
        let last = try #require(manager.tabs.first { $0.title == "Last" }?.id)
        return (first, manager.tabs[dirtyIndex].id, last)
    }

    @Test("Don't Save on a background tab leaves the tab the user was on in front")
    func dontSaveKeepsTheTabInFront() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let tabs = try openTabs(in: harness)
        harness.coordinator.tabManager.selectedTabId = tabs.first
        harness.actions.confirmSaveChanges = { _, _ in .dontSave }

        await harness.actions.closeTabAwaiting(id: tabs.dirty)

        #expect(!harness.coordinator.tabManager.tabs.contains { $0.id == tabs.dirty })
        #expect(harness.coordinator.tabManager.selectedTabId == tabs.first)
    }

    @Test("Cancel leaves the tab open and the tab the user was on in front")
    func cancelRestoresTheSelection() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let tabs = try openTabs(in: harness)
        harness.coordinator.tabManager.selectedTabId = tabs.first
        harness.actions.confirmSaveChanges = { _, _ in .cancel }

        await harness.actions.closeTabAwaiting(id: tabs.dirty)

        #expect(harness.coordinator.tabManager.tabs.contains { $0.id == tabs.dirty })
        #expect(harness.coordinator.tabManager.selectedTabId == tabs.first)
    }

    // A save can wait on the server with the strip still live.
    @Test("A tab picked while the close was pending stays in front after the close")
    func aTabPickedMeanwhileStaysInFront() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let tabs = try openTabs(in: harness)
        let manager = harness.coordinator.tabManager
        manager.selectedTabId = tabs.first
        harness.actions.confirmSaveChanges = { _, _ in
            manager.selectedTabId = tabs.last
            return .dontSave
        }

        await harness.actions.closeTabAwaiting(id: tabs.dirty)

        #expect(!manager.tabs.contains { $0.id == tabs.dirty })
        #expect(manager.selectedTabId == tabs.last)
    }

    @Test("A tab picked before Cancel stays in front")
    func aTabPickedBeforeCancelStaysInFront() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let tabs = try openTabs(in: harness)
        let manager = harness.coordinator.tabManager
        manager.selectedTabId = tabs.first
        harness.actions.confirmSaveChanges = { _, _ in
            manager.selectedTabId = tabs.last
            return .cancel
        }

        await harness.actions.closeTabAwaiting(id: tabs.dirty)

        #expect(manager.tabs.contains { $0.id == tabs.dirty })
        #expect(manager.selectedTabId == tabs.last)
    }

    @Test("Closing the tab in front still lands on its neighbour")
    func closingTheFrontTabLandsOnTheNeighbour() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let tabs = try openTabs(in: harness)
        harness.coordinator.tabManager.selectedTabId = tabs.dirty
        harness.actions.confirmSaveChanges = { _, _ in .dontSave }

        await harness.actions.closeTabAwaiting(id: tabs.dirty)

        #expect(harness.coordinator.tabManager.selectedTabId == tabs.last)
    }

    private func runningQuery(in tab: UUID, stopped: @escaping @MainActor () -> Void) -> RunningWork {
        RunningWork(
            kind: .query,
            subject: "Dirty",
            connectionName: "db_a",
            connectionIds: [],
            tabId: tab,
            cancel: stopped
        )
    }

    @Test("Cancelling the save question leaves the tab's running work running")
    func cancelledSaveKeepsWorkRunning() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let tabs = try openTabs(in: harness)
        var stops = 0
        var asked: [String] = []
        let work = runningQuery(in: tabs.dirty) { stops += 1 }
        harness.actions.runningWork = { scope in [work].filter(scope.contains) }
        harness.actions.confirmSaveChanges = { message, _ in
            asked.append(message)
            return .cancel
        }

        await harness.actions.closeTabAwaiting(id: tabs.dirty)

        #expect(stops == 0)
        #expect(asked.count == 1)
        #expect(asked.first?.contains("Running query in “Dirty”") == true)
        #expect(harness.coordinator.tabManager.tabs.contains { $0.id == tabs.dirty })
    }

    @Test("Don't Save stops the running work once, with the one question it asked")
    func dontSaveStopsWorkOnce() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let tabs = try openTabs(in: harness)
        var stops = 0
        var workQuestions = 0
        let work = runningQuery(in: tabs.dirty) { stops += 1 }
        harness.actions.runningWork = { scope in [work].filter(scope.contains) }
        harness.actions.confirmStoppingWork = { _, _ in
            workQuestions += 1
            return true
        }
        harness.actions.confirmSaveChanges = { _, _ in .dontSave }

        await harness.actions.closeTabAwaiting(id: tabs.dirty)

        #expect(stops == 1)
        #expect(workQuestions == 0)
        #expect(!harness.coordinator.tabManager.tabs.contains { $0.id == tabs.dirty })
    }

    @Test("A clean tab with running work asks about the work alone, and a no keeps it")
    func cleanTabAsksAboutWork() async throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        let tabs = try openTabs(in: harness)
        var stops = 0
        let work = runningQuery(in: tabs.first) { stops += 1 }
        harness.actions.runningWork = { scope in [work].filter(scope.contains) }
        harness.actions.confirmStoppingWork = { _, _ in false }

        await harness.actions.closeTabAwaiting(id: tabs.first)

        #expect(stops == 0)
        #expect(harness.coordinator.tabManager.tabs.contains { $0.id == tabs.first })

        harness.actions.confirmStoppingWork = { _, _ in true }
        await harness.actions.closeTabAwaiting(id: tabs.first)

        #expect(stops == 1)
        #expect(!harness.coordinator.tabManager.tabs.contains { $0.id == tabs.first })
    }
}
