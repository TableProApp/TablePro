//
//  OpenTableTabTests.swift
//  TableProTests
//
//  Tests for openTableTab logic — verifies skip/open behavior
//  based on current tab state and database context.
//
//  Note: sidebarLoadingState guard and same-table fast path tests
//  live in SwitchDatabaseTests.swift to avoid duplication.
//

import Foundation
import Testing

@testable import TablePro

@Suite("OpenTableTab")
struct OpenTableTabTests {
    // MARK: - Empty tabs path (no switching)

    @Test("Adds tab directly when tabs are empty and not switching")
    @MainActor
    func addsTabDirectlyWhenTabsEmptyNotSwitching() {
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

        #expect(tabManager.tabs.isEmpty)

        coordinator.openTableTab("users")

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs.first?.tableContext.tableName == "users")
    }
}
