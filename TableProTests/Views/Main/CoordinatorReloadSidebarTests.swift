//
//  CoordinatorRefreshTablesTests.swift
//  TableProTests
//
//  Tests for MainContentCoordinator.refreshTables() —
//  verifies it updates sidebarLoadingState and populates session tables.
//

import SwiftUI
import Testing

@testable import TablePro

@Suite("CoordinatorRefreshTables")
struct CoordinatorRefreshTablesTests {
    @Test("refreshTables sets loading state to error when no driver")
    @MainActor
    func setsErrorWhenNoDriver() async {
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

        await coordinator.refreshTables()

        #expect(coordinator.sidebarLoadingState == .error("Not connected"))
    }

    @Test("sidebarLoadingState defaults to idle")
    @MainActor
    func defaultsToIdle() {
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
    }
}
