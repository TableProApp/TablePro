//
//  PaginationCoordinatorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("PaginationCoordinator navigation")
@MainActor
struct PaginationCoordinatorTests {
    private func makeCoordinator(
        pagination: PaginationState,
        loadedRowCount: Int
    ) -> (MainContentCoordinator, QueryTabManager, UUID) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table)
        tab.tableContext.tableName = "users"
        tab.pagination = pagination
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        let columns = ["id", "name"]
        let rows = (0..<loadedRowCount).map { i in columns.map { "\($0)_\(i)" as String? } }
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let tableRows = TableRows.from(
            queryRows: rows.map { row in row.map(PluginCellValue.fromOptional) },
            columns: columns,
            columnTypes: columnTypes
        )
        coordinator.setActiveTableRows(tableRows, for: tab.id)

        return (coordinator, tabManager, tab.id)
    }

    private func pagination(_ tabManager: QueryTabManager, _ tabId: UUID) -> PaginationState? {
        tabManager.tabs.first { $0.id == tabId }?.pagination
    }

    @Test("Go to page jumps to the requested page when total is known")
    func goToPageWithKnownTotal() {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            pagination: PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 1),
            loadedRowCount: 10
        )
        coordinator.goToPage(3)
        #expect(pagination(tabManager, tabId)?.currentPage == 3)
        #expect(pagination(tabManager, tabId)?.currentOffset == 20)
    }

    @Test("Go to page is ignored when total is unknown")
    func goToPageIgnoredWhenTotalUnknown() {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            pagination: PaginationState(totalRowCount: nil, pageSize: 10, currentPage: 1),
            loadedRowCount: 10
        )
        coordinator.goToPage(3)
        #expect(pagination(tabManager, tabId)?.currentPage == 1)
    }

    @Test("Next page advances on an unknown total when a full page is loaded")
    func nextPageAdvancesUnknownTotalFullPage() {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            pagination: PaginationState(totalRowCount: nil, pageSize: 5, currentPage: 1),
            loadedRowCount: 5
        )
        coordinator.goToNextPage()
        #expect(pagination(tabManager, tabId)?.currentPage == 2)
        #expect(pagination(tabManager, tabId)?.currentOffset == 5)
    }

    @Test("Next page does nothing on an unknown total when a partial page is loaded")
    func nextPageNoOpUnknownTotalPartialPage() {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            pagination: PaginationState(totalRowCount: nil, pageSize: 10, currentPage: 1),
            loadedRowCount: 4
        )
        coordinator.goToNextPage()
        #expect(pagination(tabManager, tabId)?.currentPage == 1)
    }

    @Test("Last page is ignored when total is unknown")
    func lastPageIgnoredWhenTotalUnknown() {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            pagination: PaginationState(totalRowCount: nil, pageSize: 5, currentPage: 2, currentOffset: 5),
            loadedRowCount: 5
        )
        coordinator.goToLastPage()
        #expect(pagination(tabManager, tabId)?.currentPage == 2)
    }
}
