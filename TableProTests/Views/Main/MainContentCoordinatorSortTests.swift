//
//  MainContentCoordinatorSortTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("MainContentCoordinator handleSort")
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
        let tableRows = TableRows.from(queryRows: rows, columns: columns, columnTypes: columnTypes)
        coordinator.setActiveTableRows(tableRows, for: tabId)
    }

    // MARK: - Single column sort

    @Test("Single sort writes ascending state on a fresh tab")
    func singleSortWritesAscendingState() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSort(columnIndex: 1, ascending: true, isMultiSort: false)

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 1, direction: .ascending)
        ])
        #expect(tabManager.tabs[idx].hasUserInteraction == true)
    }

    @Test("Single sort flips ascending to descending on the same column")
    func singleSortFlipsToDescending() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSort(columnIndex: 1, ascending: true, isMultiSort: false)
        coordinator.handleSort(columnIndex: 1, ascending: false, isMultiSort: false)

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 1, direction: .descending)
        ])
    }

    @Test("Single sort on a different column replaces the existing sort")
    func singleSortReplacesAcrossColumns() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSort(columnIndex: 0, ascending: true, isMultiSort: false)
        coordinator.handleSort(columnIndex: 2, ascending: true, isMultiSort: false)

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 2, direction: .ascending)
        ])
    }

    @Test("Out-of-range column index is rejected and state stays unchanged")
    func outOfRangeColumnIndexIsIgnored() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSort(columnIndex: 99, ascending: true, isMultiSort: false)

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns.isEmpty)
    }

    @Test("Negative column index is rejected and state stays unchanged")
    func negativeColumnIndexIsIgnored() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSort(columnIndex: -1, ascending: true, isMultiSort: false)

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns.isEmpty)
    }

    // MARK: - Multi column sort

    @Test("Multi-sort appends a new column to the existing sort")
    func multiSortAppendsNewColumn() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSort(columnIndex: 0, ascending: true, isMultiSort: false)
        coordinator.handleSort(columnIndex: 2, ascending: true, isMultiSort: true)

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 0, direction: .ascending),
            SortColumn(columnIndex: 2, direction: .ascending)
        ])
    }

    @Test("Multi-sort toggles direction on an existing secondary column")
    func multiSortTogglesSecondaryDirection() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSort(columnIndex: 0, ascending: true, isMultiSort: false)
        coordinator.handleSort(columnIndex: 2, ascending: true, isMultiSort: true)
        coordinator.handleSort(columnIndex: 2, ascending: false, isMultiSort: true)

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 0, direction: .ascending),
            SortColumn(columnIndex: 2, direction: .descending)
        ])
    }

    @Test("Multi-sort with same direction on existing column removes that column")
    func multiSortSameDirectionRemovesColumn() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSort(columnIndex: 0, ascending: true, isMultiSort: false)
        coordinator.handleSort(columnIndex: 2, ascending: false, isMultiSort: true)
        coordinator.handleSort(columnIndex: 2, ascending: false, isMultiSort: true)

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 0, direction: .ascending)
        ])
    }

    @Test("Multi-sort preserves the primary column when adding a secondary")
    func multiSortKeepsPrimaryColumn() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSort(columnIndex: 0, ascending: false, isMultiSort: false)
        coordinator.handleSort(columnIndex: 1, ascending: true, isMultiSort: true)

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns.first == SortColumn(columnIndex: 0, direction: .descending))
        #expect(tabManager.tabs[idx].sortState.columns.count == 2)
    }

    @Test("removeMultiSortColumn drops the targeted column from the sort list")
    func removeMultiSortColumnDropsColumn() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSort(columnIndex: 0, ascending: true, isMultiSort: false)
        coordinator.handleSort(columnIndex: 1, ascending: false, isMultiSort: true)

        coordinator.removeMultiSortColumn(columnIndex: 1)

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 0, direction: .ascending)
        ])
    }

    @Test("removeMultiSortColumn is a no-op when the column is not in the sort")
    func removeMultiSortColumnNoOpForUnsortedColumn() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSort(columnIndex: 0, ascending: true, isMultiSort: false)

        coordinator.removeMultiSortColumn(columnIndex: 1)

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns == [
            SortColumn(columnIndex: 0, direction: .ascending)
        ])
    }

    // MARK: - Cache invariants

    @Test("clearSort on a query tab removes the cache entry for that tab")
    func clearSortRemovesCacheEntry() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSort(columnIndex: 0, ascending: true, isMultiSort: false)
        coordinator.querySortCache[tabId] = QuerySortCacheEntry(
            sortedIDs: [.existing(0), .existing(1), .existing(2)],
            columnIndex: 0,
            direction: .ascending,
            schemaVersion: 0
        )

        coordinator.clearSort()

        #expect(coordinator.querySortCache[tabId] == nil)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns.isEmpty)
    }

    @Test("clearSort on an unsorted tab does not crash and leaves sort state empty")
    func clearSortIsNoOpWhenUnsorted() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.clearSort()

        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[idx].sortState.columns.isEmpty)
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

    // MARK: - Pagination reset

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

        coordinator.handleSort(columnIndex: 0, ascending: true, isMultiSort: false)

        #expect(tabManager.tabs[idx].pagination.currentPage == 1)
        #expect(tabManager.tabs[idx].pagination.currentOffset == 0)
    }
}
