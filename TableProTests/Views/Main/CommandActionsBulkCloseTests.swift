//
//  CommandActionsBulkCloseTests.swift
//  TableProTests
//
//  Covers the bulk tab-close commands: which of the connection's tabs they target and
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

    /// A connection keeps one tab list now, so the scope of a database-scoped close is that list.
    /// These used to spread a connection's tabs over sibling windows and check that the command
    /// reached across them, which is a shape the app can no longer be in.
    @Test("a tab on another database is offered for closing")
    func canCloseTabsForOtherDatabasesWhenATabIsForeign() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        current.coordinator.tabManager.addTab(initialQuery: "SELECT 2", databaseName: "db_b")

        #expect(current.actions.browseDatabaseName == "db_a")
        #expect(current.actions.canCloseTabsForOtherDatabases)
    }

    @Test("nothing is offered when every tab is on the active database")
    func cannotCloseTabsForOtherDatabasesWhenAllMatch() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        current.coordinator.tabManager.addTab(initialQuery: "SELECT 2", databaseName: "db_a")

        #expect(!current.actions.canCloseTabsForOtherDatabases)
    }

    /// Another connection's tabs are out of scope by construction rather than by a filter: they
    /// live in that connection's own tab list, which this command never reads.
    @Test("another connection's tabs are never a database-scoped target")
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
        #expect(unrelated.actions.canCloseTabsForOtherDatabases == false)
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
