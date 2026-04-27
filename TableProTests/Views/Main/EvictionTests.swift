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

    private func addLoadedTab(
        to coordinator: MainContentCoordinator,
        tabManager: QueryTabManager,
        tableName: String = "users"
    ) {
        tabManager.addTableTab(tableName: tableName)
        guard let index = tabManager.selectedTabIndex else { return }
        let rows = TestFixtures.makeRows(count: 10)
        let tabId = tabManager.tabs[index].id
        let buffer = coordinator.rowDataStore.buffer(for: tabId)
        buffer.rows = rows
        buffer.columns = ["id", "name", "email"]
        tabManager.tabs[index].execution.lastExecutedAt = Date()
    }

    @Test("evictInactiveRowData evicts loaded tabs without pending changes")
    func evictsLoadedTabs() {
        let (coordinator, tabManager) = makeCoordinator()
        addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let tabId = tabManager.tabs[0].id
        let buffer = coordinator.rowDataStore.buffer(for: tabId)

        #expect(buffer.rows.count == 10)
        #expect(buffer.isEvicted == false)

        coordinator.evictInactiveRowData()

        #expect(buffer.isEvicted == true)
        #expect(buffer.rows.isEmpty)
    }

    @Test("evictInactiveRowData skips tabs with pending changes")
    func skipsTabsWithPendingChanges() {
        let (coordinator, tabManager) = makeCoordinator()
        addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")

        tabManager.tabs[0].pendingChanges.deletedRowIndices = [0]

        coordinator.evictInactiveRowData()

        let buffer = coordinator.rowDataStore.buffer(for: tabManager.tabs[0].id)
        #expect(buffer.isEvicted == false)
        #expect(buffer.rows.count == 10)
    }

    @Test("evictInactiveRowData skips already evicted tabs")
    func skipsAlreadyEvicted() {
        let (coordinator, tabManager) = makeCoordinator()
        addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")

        let buffer = coordinator.rowDataStore.buffer(for: tabManager.tabs[0].id)
        buffer.evict()
        #expect(buffer.isEvicted == true)

        coordinator.evictInactiveRowData()
        #expect(buffer.isEvicted == true)
    }

    @Test("evictInactiveRowData skips tabs with empty results")
    func skipsEmptyResults() {
        let (coordinator, tabManager) = makeCoordinator()
        tabManager.addTableTab(tableName: "empty_table")

        coordinator.evictInactiveRowData()

        let buffer = coordinator.rowDataStore.buffer(for: tabManager.tabs[0].id)
        #expect(buffer.isEvicted == false)
    }

    @Test("evictInactiveRowData preserves column metadata after eviction")
    func preservesMetadataAfterEviction() {
        let (coordinator, tabManager) = makeCoordinator()
        addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")

        coordinator.evictInactiveRowData()

        let buffer = coordinator.rowDataStore.buffer(for: tabManager.tabs[0].id)
        #expect(buffer.columns == ["id", "name", "email"])
        #expect(buffer.isEvicted == true)
    }

    @Test("evictInactiveRowData with no tabs is no-op")
    func noTabsIsNoOp() {
        let (coordinator, _) = makeCoordinator()
        coordinator.evictInactiveRowData()
    }
}
