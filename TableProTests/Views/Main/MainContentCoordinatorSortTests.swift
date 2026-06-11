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

    @Test("Applying an empty state clears the sort")
    func emptyStateClearsSort() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)

        coordinator.handleSortStateChanged(sortState([(0, .ascending)]))
        coordinator.handleSortStateChanged(SortState())

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


    @Test("Sorting a paginated query result does not overwrite the editor query")
    func paginatedSortPreservesContentQuery() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        let originalQuery = tabManager.tabs[idx].content.query
        tabManager.tabs[idx].pagination.hasMoreRows = true
        tabManager.tabs[idx].pagination.baseQueryForMore = originalQuery

        coordinator.handleSortStateChanged(sortState([(0, .ascending)]))

        #expect(tabManager.tabs[idx].content.query == originalQuery)
    }

    @Test("Sorting a file-backed paginated query tab does not mark it dirty")
    func paginatedSortKeepsFileTabClean() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        let originalQuery = tabManager.tabs[idx].content.query
        tabManager.tabs[idx].content.sourceFileURL = URL(fileURLWithPath: "/tmp/query.sql")
        tabManager.tabs[idx].content.savedFileContent = originalQuery
        tabManager.tabs[idx].pagination.hasMoreRows = true
        tabManager.tabs[idx].pagination.baseQueryForMore = originalQuery

        coordinator.handleSortStateChanged(sortState([(1, .descending)]))

        #expect(tabManager.tabs[idx].content.query == originalQuery)
        #expect(tabManager.tabs[idx].content.isFileDirty == false)
    }

    @Test("Clearing sort on a paginated query tab keeps the editor query intact")
    func clearingSortPaginatedPreservesContentQuery() {
        let (coordinator, tabManager, tabId) = makeCoordinator()
        seedRows(coordinator, for: tabId)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        let originalQuery = tabManager.tabs[idx].content.query
        tabManager.tabs[idx].sortState = sortState([(0, .ascending)])
        tabManager.tabs[idx].pagination.hasMoreRows = true
        tabManager.tabs[idx].pagination.baseQueryForMore = originalQuery

        coordinator.handleSortStateChanged(SortState())

        #expect(tabManager.tabs[idx].content.query == originalQuery)
        #expect(tabManager.tabs[idx].sortState.columns.isEmpty)
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
