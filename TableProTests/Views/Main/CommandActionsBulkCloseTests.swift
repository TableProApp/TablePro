//
//  CommandActionsBulkCloseTests.swift
//  TableProTests
//
//  Covers the bulk tab-close commands: which sibling windows they target and
//  that the surviving window empties in place instead of closing (#1972).
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor @Suite("CommandActions Bulk Close")
struct CommandActionsBulkCloseTests {
    private struct Window {
        let actions: MainContentCommandActions
        let coordinator: MainContentCoordinator
        let window: NSWindow
    }

    private func makeWindow(connection: DatabaseConnection) -> Window {
        let state = SessionStateFactory.create(connection: connection, payload: nil)
        let coordinator = state.coordinator

        var selectedTables: Set<TableInfo> = []
        var pendingTruncates: Set<String> = []
        var pendingDeletes: Set<String> = []
        var tableOperationOptions: [String: TableOperationOptions] = [:]

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
            rightPanelState: RightPanelState()
        )

        let window = NSWindow()
        coordinator.contentWindow = window
        actions.window = window

        return Window(actions: actions, coordinator: coordinator, window: window)
    }

    // MARK: - Survivor

    @Test("the surviving window empties in place instead of closing")
    func survivorClearsTabsInPlace() async {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let survivor = makeWindow(connection: connection)
        defer { survivor.coordinator.teardown() }

        survivor.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        #expect(survivor.coordinator.tabManager.tabs.count == 1)

        let outcome = await survivor.actions.closeWindowAwaiting(asBatchSurvivor: true)

        #expect(outcome == .closed)
        #expect(survivor.coordinator.tabManager.tabs.isEmpty)
        #expect(survivor.coordinator.tabManager.selectedTabId == nil)
    }

    // MARK: - Database scope

    @Test("a sibling window on another database is offered for closing")
    func canCloseTabsForOtherDatabasesWhenSiblingIsForeign() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        let sibling = makeWindow(connection: connection)
        defer {
            current.coordinator.teardown()
            sibling.coordinator.teardown()
        }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        sibling.coordinator.tabManager.addTab(initialQuery: "SELECT 2", databaseName: "db_b")

        #expect(current.actions.activeDatabaseName == "db_a")
        #expect(current.actions.canCloseTabsForOtherDatabases)
    }

    @Test("nothing is offered when every sibling is on the active database")
    func cannotCloseTabsForOtherDatabasesWhenAllMatch() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        let sibling = makeWindow(connection: connection)
        defer {
            current.coordinator.teardown()
            sibling.coordinator.teardown()
        }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        sibling.coordinator.tabManager.addTab(initialQuery: "SELECT 2", databaseName: "db_a")

        #expect(!current.actions.canCloseTabsForOtherDatabases)
    }

    @Test("another connection's window is never a database-scoped target")
    func otherConnectionsAreOutOfScope() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let otherConnection = TestFixtures.makeConnection(database: "db_b")
        let current = makeWindow(connection: connection)
        let unrelated = makeWindow(connection: otherConnection)
        defer {
            current.coordinator.teardown()
            unrelated.coordinator.teardown()
        }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        unrelated.coordinator.tabManager.addTab(initialQuery: "SELECT 2", databaseName: "db_b")

        #expect(!current.actions.canCloseTabsForOtherDatabases)
    }

    // MARK: - Enablement

    @Test("closing all tabs is offered while the window still holds a tab")
    func canCloseAllTabsFollowsOpenTabs() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        #expect(!current.actions.canCloseAllTabs)

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")

        #expect(current.actions.canCloseAllTabs)
    }
}
