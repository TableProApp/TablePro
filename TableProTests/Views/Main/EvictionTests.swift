//
//  EvictionTests.swift
//  TableProTests
//
//  Tests for cross-window tab eviction
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("Cross-Window Tab Eviction")
@MainActor
struct EvictionTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let toolbarState = ConnectionToolbarState()
        let connection = TestFixtures.makeConnection()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            toolbarState: toolbarState
        )
        return (coordinator, tabManager)
    }

    private func addLoadedTab(
        to coordinator: MainContentCoordinator,
        tabManager: QueryTabManager,
        tableName: String = "users"
    ) throws {
        try tabManager.addTableTab(tableName: tableName)
        guard let index = tabManager.selectedTabIndex else { return }
        let rows = TestFixtures.makeRows(count: 10)
        let tabId = tabManager.tabs[index].id
        let columns = ["id", "name", "email"]
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let tableRows = TableRows.from(queryRows: rows.map { row in row.map(PluginCellValue.fromOptional) }, columns: columns, columnTypes: columnTypes)
        coordinator.setActiveTableRows(tableRows, for: tabId)
        tabManager.tabs[index].execution.lastExecutedAt = Date()
    }

    @Test("evictInactiveRowData evicts background tabs without pending changes")
    func evictsLoadedTabs() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).rows.count == 10)
        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == false)

        coordinator.evictInactiveRowData()

        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == true)
        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).rows.isEmpty)
    }

    @Test("evictInactiveRowData skips tabs with pending changes")
    func skipsTabsWithPendingChanges() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")

        tabManager.tabs[0].pendingChanges.deletedRowIndices = [0]

        coordinator.evictInactiveRowData()

        let tabId = tabManager.tabs[0].id
        #expect(coordinator.tabSessionRegistry.isEvicted(tabId) == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: tabId).rows.count == 10)
    }

    @Test("evictInactiveRowData preserves column metadata after eviction")
    func preservesMetadataAfterEviction() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()

        let rows = coordinator.tabSessionRegistry.tableRows(for: backgroundTabId)
        #expect(rows.columns == ["id", "name", "email"])
        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == true)
    }

    @Test("evictInactiveRowData with no tabs is no-op")
    func noTabsIsNoOp() {
        let (coordinator, _) = makeCoordinator()
        coordinator.evictInactiveRowData()
    }
}
