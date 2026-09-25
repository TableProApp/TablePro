//
//  CommandActionsCloseSelectionTests.swift
//  TableProTests
//
//  Closing a tab that holds unsaved work selects it first so the save question has something to
//  point at. Whatever the answer, the selection then goes back to the tab the user was working in.
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
            selectionState: coordinator.selectionState,
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

    /// Three query tabs, the middle one holding a `.sql` file emptied since it was saved. Empty, so
    /// no close here files an entry in the Recently Closed Tabs history of whoever runs the suite.
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

    /// The reported case: the background tab closed after Don't Save, and the window showed its
    /// neighbour instead of the tab the user had in front.
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

    /// A save can wait on the server after the prompt with the strip still live. Whatever the user
    /// picked in that time is newer than the tab the close set aside.
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
}
