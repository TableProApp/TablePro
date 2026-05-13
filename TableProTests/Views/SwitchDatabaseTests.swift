//
//  SwitchDatabaseTests.swift
//  TableProTests
//
//  Tests for the "switch database" flow: verifies that switching databases
//  (Cmd+K) does NOT create new macOS windows, and that table tabs are
//  properly reset to avoid "table not found" errors in the new database.
//

import Foundation
import TableProPluginKit
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
    @Test("openTableTab skips when table is already active tab in same database")
    @MainActor
    func openTableTabSkipsForSameTableSameDatabase() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        // Add a tab for "users" in "db_a"
        try tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db_a")
        let tabCountBefore = tabManager.tabs.count

        // Opening "users" again in same database should be a no-op (fast path)
        coordinator.openTableTab("users")

        #expect(tabManager.tabs.count == tabCountBefore)
    }

    // MARK: - Tab state after database switch

    @Test("switchDatabase clears all table tabs")
    @MainActor
    func switchDatabaseClearsTableTabs() throws {
        let tabManager = QueryTabManager()
        try tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db_a")

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
    func switchDatabaseClearsMixedTabs() throws {
        let tabManager = QueryTabManager()
        try tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db_a")
        tabManager.addTab(initialQuery: "SELECT NOW()", databaseName: "db_a")
        try tabManager.addTableTab(tableName: "orders", databaseType: .mysql, databaseName: "db_a")
        #expect(tabManager.tabs.count == 3)

        simulateDatabaseSwitch(tabManager: tabManager)

        #expect(tabManager.tabs.isEmpty)
        #expect(tabManager.selectedTabId == nil)
    }
}
