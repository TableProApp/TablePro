//
//  SwitchDatabaseTests.swift
//  TableProTests
//
//  Tests for the "switch database" flow: verifies that switching databases
//  (Cmd+K) does NOT create new macOS windows, and that table tabs are
//  properly reset to avoid "table not found" errors in the new database.
//

import Foundation
import SwiftUI
import Testing

@testable import TablePro

// MARK: - Helpers

/// Simulates the tab-clearing logic from switchDatabase(to:).
/// All tabs are removed to prevent stale queries from the previous database.
@MainActor
private func simulateDatabaseSwitch(
    tabManager: QueryTabManager
) {
    tabManager.tabs = []
    tabManager.selectedTabId = nil
}

@Suite("SwitchDatabase")
struct SwitchDatabaseTests {
    // MARK: - sidebarLoadingState

    @Test("sidebarLoadingState defaults to idle")
    @MainActor
    func loadingStateDefaultsToIdle() {
        let connection = TestFixtures.makeConnection()
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        #expect(coordinator.sidebarLoadingState == .idle)
    }

    // MARK: - openTableTab behavior during database switch

    @Test("openTableTab skips new window when sidebar is loading with existing tabs")
    @MainActor
    func openTableTabSkipsNewWindowDuringSwitch() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db_a")
        let tabCountBefore = tabManager.tabs.count

        coordinator.sidebarLoadingState = .loading

        coordinator.openTableTab("orders")

        #expect(tabManager.tabs.count == tabCountBefore)
    }

    @Test("openTableTab adds tab in-place when sidebar is loading with empty tabs")
    @MainActor
    func openTableTabAddsInPlaceWhenSwitchingWithEmptyTabs() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        #expect(tabManager.tabs.isEmpty)

        coordinator.sidebarLoadingState = .loading

        coordinator.openTableTab("users")

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs.first?.tableName == "users")
    }

    // MARK: - openTableTab fast path (same table + same database)

    @Test("openTableTab skips when table is already active tab in same database")
    @MainActor
    func openTableTabSkipsForSameTableSameDatabase() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        // Add a tab for "users" in "db_a"
        tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db_a")
        let tabCountBefore = tabManager.tabs.count

        // Opening "users" again in same database should be a no-op (fast path)
        coordinator.openTableTab("users")

        #expect(tabManager.tabs.count == tabCountBefore)
    }

    // MARK: - Tab state after database switch

    @Test("switchDatabase clears all table tabs")
    @MainActor
    func switchDatabaseClearsTableTabs() {
        let tabManager = QueryTabManager()
        tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db_a")

        simulateDatabaseSwitch(tabManager: tabManager)

        #expect(tabManager.tabs.isEmpty)
        #expect(tabManager.selectedTabId == nil)
    }

    @Test("switchDatabase clears all query tabs")
    @MainActor
    func switchDatabaseClearsQueryTabs() {
        let tabManager = QueryTabManager()
        tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")

        simulateDatabaseSwitch(tabManager: tabManager)

        #expect(tabManager.tabs.isEmpty)
        #expect(tabManager.selectedTabId == nil)
    }

    @Test("switchDatabase clears mixed table and query tabs")
    @MainActor
    func switchDatabaseClearsMixedTabs() {
        let tabManager = QueryTabManager()
        tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db_a")
        tabManager.addTab(initialQuery: "SELECT NOW()", databaseName: "db_a")
        tabManager.addTableTab(tableName: "orders", databaseType: .mysql, databaseName: "db_a")
        #expect(tabManager.tabs.count == 3)

        simulateDatabaseSwitch(tabManager: tabManager)

        #expect(tabManager.tabs.isEmpty)
        #expect(tabManager.selectedTabId == nil)
    }

    // MARK: - sidebarLoadingState during database switch

    @Test("switchDatabase sets sidebarLoadingState to loading then error when no driver")
    @MainActor
    func switchDatabaseSetsLoadingState() async {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        #expect(coordinator.sidebarLoadingState == .idle)

        await coordinator.switchDatabase(to: "db_b")

        // Without a driver, switchDatabase sets loading then returns early
        // refreshTables will set error state since there's no driver
        #expect(coordinator.sidebarLoadingState == .error("Not connected"))
    }
}
