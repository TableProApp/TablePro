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
        try tabManager.addTableTab(tableName: tableName)
        guard let index = tabManager.selectedTabIndex else { return }
        let rows = TestFixtures.makeRows(count: 10)
        let tabId = tabManager.tabs[index].id
        let columns = ["id", "name", "email"]
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let tableRows = TableRows.from(queryRows: rows, columns: columns, columnTypes: columnTypes)
        coordinator.setActiveTableRows(tableRows, for: tabId)
        tabManager.tabs[index].execution.lastExecutedAt = Date()
    }

    @Test("evictInactiveRowData evicts background tabs without pending changes")
    func evictsLoadedTabs() {
        let (coordinator, tabManager) = makeCoordinator()
        addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        // Add a second tab so the first becomes background (eviction skips the selected tab)
        addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        #expect(coordinator.tableRowsStore.tableRows(for: backgroundTabId).rows.count == 10)
        #expect(coordinator.tableRowsStore.isEvicted(backgroundTabId) == false)

        coordinator.evictInactiveRowData()

        #expect(coordinator.tableRowsStore.isEvicted(backgroundTabId) == true)
        #expect(coordinator.tableRowsStore.tableRows(for: backgroundTabId).rows.isEmpty)
    }

    @Test("evictInactiveRowData skips tabs with pending changes")
    func skipsTabsWithPendingChanges() {
        let (coordinator, tabManager) = makeCoordinator()
        addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")

        tabManager.tabs[0].pendingChanges.deletedRowIndices = [0]

        coordinator.evictInactiveRowData()

        let tabId = tabManager.tabs[0].id
        #expect(coordinator.tableRowsStore.isEvicted(tabId) == false)
        #expect(coordinator.tableRowsStore.tableRows(for: tabId).rows.count == 10)
    }

    @Test("evictInactiveRowData preserves column metadata after eviction")
    func preservesMetadataAfterEviction() {
        let (coordinator, tabManager) = makeCoordinator()
        addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()

        let rows = coordinator.tableRowsStore.tableRows(for: backgroundTabId)
        #expect(rows.columns == ["id", "name", "email"])
        #expect(coordinator.tableRowsStore.isEvicted(backgroundTabId) == true)
    }

    @Test("evictInactiveRowData with no tabs is no-op")
    func noTabsIsNoOp() {
        let (coordinator, _) = makeCoordinator()
        coordinator.evictInactiveRowData()
    }
}
