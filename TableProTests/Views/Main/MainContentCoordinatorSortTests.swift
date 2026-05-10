//
//  MainContentCoordinatorSortTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MainContentCoordinator handleSortStateChanged")
@MainActor
struct MainContentCoordinatorSortTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager, UUID) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "Q1", query: "SELECT id, name, email FROM users", tabType: .query)
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return (coordinator, tabManager, tab.id)
    }

    private func seedRows(
        _ coordinator: MainContentCoordinator,
        for tabId: UUID,
        columns: [String] = ["id", "name", "email"],
        rowCount: Int = 5
    ) {
        let rows = (0..<rowCount).map { i in columns.map { "\($0)_\(i)" as String? } }
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let tableRows = TableRows.from(queryRows: rows.map { row in row.map(PluginCellValue.fromOptional) }, columns: columns, columnTypes: columnTypes)
        coordinator.setActiveTableRows(tableRows, for: tabId)
    }

    private func sortState(_ columns: [(Int, SortDirection)]) -> SortState {
        var state = SortState()
        state.columns = columns.map { SortColumn(columnIndex: $0.0, direction: $0.1) }
        return state
    }

    @Test("Applying a single-column ascending state writes it to the tab")
    func appliesSingleColumnAscending() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSortStateChanged(sortState([(1, .ascending)]))

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 1, direction: .ascending)
        ])
        #expect(tabManager.tabs[idx].hasUserInteraction == true)
    }

    @Test("Applying a different state replaces the previous one")
    func replacesPreviousState() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSortStateChanged(sortState([(0, .ascending)]))
        coordinator.handleSortStateChanged(sortState([(2, .descending)]))

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 2, direction: .descending)
        ])
    }

    @Test("Applying a multi-column state writes all columns in order")
    func appliesMultiColumnState() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSortStateChanged(sortState([
            (0, .ascending),
            (2, .descending)
        ]))

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 0, direction: .ascending),
            SortColumn(columnIndex: 2, direction: .descending)
        ])
    }

    @Test("Applying an empty state clears the sort and removes the cache entry")
    func emptyStateClearsSortAndCache() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSortStateChanged(sortState([(0, .ascending)]))
        coordinator.querySortCache[tabId] = QuerySortCacheEntry(
            sortedIDs: [.existing(0), .existing(1), .existing(2)],
            columnIndex: 0,
            direction: .ascending,
            schemaVersion: 0
        )

        coordinator.handleSortStateChanged(SortState())

        #expect(coordinator.querySortCache[tabId] == nil)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns.isEmpty)
    }

    @Test("Applying the same state twice is a no-op")
    func sameStateIsNoOp() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)
        let state = sortState([(0, .ascending)])

        coordinator.handleSortStateChanged(state)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        let firstInteractionTimestamp = tabManager.tabs[idx].hasUserInteraction
        coordinator.handleSortStateChanged(state)

        #expect(tabManager.tabs[idx].sortState.columns == state.columns)
        #expect(tabManager.tabs[idx].hasUserInteraction == firstInteractionTimestamp)
    }

    @Test("cleanupSortCache drops entries for tabs that are no longer open")
    func cleanupSortCacheDropsClosedTabs() {
        let (coordinator, _, tabId) = makeCoordinator()
        let strayTabId = UUID()
        coordinator.querySortCache[tabId] = QuerySortCacheEntry(
            sortedIDs: [.existing(0)],
            columnIndex: 0,
            direction: .ascending,
            schemaVersion: 0
        )
        coordinator.querySortCache[strayTabId] = QuerySortCacheEntry(
            sortedIDs: [.existing(0)],
            columnIndex: 0,
            direction: .ascending,
            schemaVersion: 0
        )

        coordinator.cleanupSortCache(openTabIds: [tabId])

        #expect(coordinator.querySortCache[tabId] != nil)
        #expect(coordinator.querySortCache[strayTabId] == nil)
    }

    @Test("Sort resets pagination on the active tab")
    func sortResetsPagination() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        tabManager.tabs[idx].pagination.currentPage = 5
        tabManager.tabs[idx].pagination.currentOffset = 4_000

        coordinator.handleSortStateChanged(sortState([(0, .ascending)]))

        #expect(tabManager.tabs[idx].pagination.currentPage == 1)
        #expect(tabManager.tabs[idx].pagination.currentOffset == 0)
    }
}
