//
//  EvictionTests.swift
//  TableProTests
//
//  Tests for cross-window tab eviction
//

import Foundation
import Testing
@testable import TablePro

@Suite("Cross-Window Tab Eviction")
@MainActor
struct EvictionTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()
        let connection = TestFixtures.makeConnection()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        return (coordinator, tabManager)
    }

    private func addLoadedTab(to tabManager: QueryTabManager, tableName: String = "users") {
        tabManager.addTableTab(tableName: tableName)
        guard let index = tabManager.selectedTabIndex else { return }
        let rows = TestFixtures.makeQueryResultRows(count: 10)
        tabManager.tabs[index].rowBuffer.rows = rows
        tabManager.tabs[index].rowBuffer.columns = ["id", "name", "email"]
        tabManager.tabs[index].lastExecutedAt = Date()
    }

    @Test("evictInactiveRowData evicts loaded tabs without pending changes")
    func evictsLoadedTabs() {
        let (coordinator, tabManager) = makeCoordinator()
        addLoadedTab(to: tabManager, tableName: "users")

        #expect(tabManager.tabs[0].resultRows.count == 10)
        #expect(tabManager.tabs[0].rowBuffer.isEvicted == false)

        coordinator.evictInactiveRowData()

        #expect(tabManager.tabs[0].rowBuffer.isEvicted == true)
        #expect(tabManager.tabs[0].resultRows.isEmpty)
    }

    @Test("evictInactiveRowData skips tabs with pending changes")
    func skipsTabsWithPendingChanges() {
        let (coordinator, tabManager) = makeCoordinator()
        addLoadedTab(to: tabManager, tableName: "users")

        // Add a pending change
        tabManager.tabs[0].pendingChanges.deletedRowIndices = [0]

        coordinator.evictInactiveRowData()

        // Should NOT be evicted because it has pending changes
        #expect(tabManager.tabs[0].rowBuffer.isEvicted == false)
        #expect(tabManager.tabs[0].resultRows.count == 10)
    }

    @Test("evictInactiveRowData skips already evicted tabs")
    func skipsAlreadyEvicted() {
        let (coordinator, tabManager) = makeCoordinator()
        addLoadedTab(to: tabManager, tableName: "users")

        // Pre-evict
        tabManager.tabs[0].rowBuffer.evict()
        #expect(tabManager.tabs[0].rowBuffer.isEvicted == true)

        // Should not crash or change state
        coordinator.evictInactiveRowData()
        #expect(tabManager.tabs[0].rowBuffer.isEvicted == true)
    }

    @Test("evictInactiveRowData skips tabs with empty results")
    func skipsEmptyResults() {
        let (coordinator, tabManager) = makeCoordinator()
        tabManager.addTableTab(tableName: "empty_table")
        // Don't add any rows — resultRows is empty

        coordinator.evictInactiveRowData()

        // Should not evict (nothing to evict)
        #expect(tabManager.tabs[0].rowBuffer.isEvicted == false)
    }

    @Test("evictInactiveRowData preserves column metadata after eviction")
    func preservesMetadataAfterEviction() {
        let (coordinator, tabManager) = makeCoordinator()
        addLoadedTab(to: tabManager, tableName: "users")

        coordinator.evictInactiveRowData()

        #expect(tabManager.tabs[0].rowBuffer.columns == ["id", "name", "email"])
        #expect(tabManager.tabs[0].rowBuffer.isEvicted == true)
    }

    @Test("evictInactiveRowData with no tabs is no-op")
    func noTabsIsNoOp() {
        let (coordinator, _) = makeCoordinator()
        // No tabs added — should not crash
        coordinator.evictInactiveRowData()
    }
}
