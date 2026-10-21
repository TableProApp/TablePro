//
//  StatusBarSnapshotTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct StatusBarSnapshotTests {
    private func makeSnapshot(
        tabType: TabType? = .table,
        rowCount: Int = 0,
        pagination: PaginationState = PaginationState(),
        statusMessage: String? = nil
    ) -> StatusBarSnapshot {
        StatusBarSnapshot(
            tabId: UUID(),
            tabType: tabType,
            hasRows: rowCount > 0,
            hasColumns: rowCount > 0,
            rowCount: rowCount,
            hasTableName: true,
            pagination: pagination,
            statusMessage: statusMessage
        )
    }

    @Test("Single page with unknown total is not treated as paged")
    func notPagedOnSinglePage() {
        let snapshot = makeSnapshot(rowCount: 10, pagination: PaginationState(totalRowCount: nil, pageSize: 50, currentPage: 1))
        #expect(!snapshot.isPagedWithUnknownTotal)
    }

    @Test("Page beyond the first is treated as paged with unknown total")
    func pagedWhenBeyondFirstPage() {
        let snapshot = makeSnapshot(rowCount: 50, pagination: PaginationState(totalRowCount: nil, pageSize: 50, currentPage: 2, currentOffset: 50))
        #expect(snapshot.isPagedWithUnknownTotal)
    }

    @Test("A full first page with unknown total is treated as paged")
    func pagedWhenFirstPageIsFull() {
        let snapshot = makeSnapshot(rowCount: 50, pagination: PaginationState(totalRowCount: nil, pageSize: 50, currentPage: 1))
        #expect(snapshot.isPagedWithUnknownTotal)
    }

    @Test("A value filter separates displayed rows from loaded rows")
    func valueFilterSplitsCounts() {
        let snapshot = StatusBarSnapshot(
            tabId: UUID(),
            tabType: .table,
            hasRows: true,
            hasColumns: true,
            rowCount: 100,
            displayRowCount: 3,
            isValueFiltered: true,
            hasTableName: true,
            pagination: PaginationState(totalRowCount: 1_000, pageSize: 100),
            statusMessage: nil
        )
        #expect(snapshot.rowCount == 100)
        #expect(snapshot.displayRowCount == 3)
        #expect(snapshot.isValueFiltered)
    }

    @Test("The footer shows the active result's own message after a run of several statements")
    func activeResultMessageReachesTheFooter() {
        let tab = QueryTab(title: "Query 1", query: "CONSISTENCY ONE; SELECT * FROM t", tabType: .query)
        let snapshot = StatusBarSnapshot(
            tab: tab,
            tableRows: TableRows(),
            activeResultStatusMessage: "Consistency: ONE"
        )
        #expect(snapshot.statusMessage == "Consistency: ONE")
    }

    @Test("With no result of its own, the footer shows the run's message")
    func runMessageWithoutAResultMessage() {
        var tab = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        tab.execution.statusMessage = "Processed: 1 GB"
        #expect(StatusBarSnapshot(tab: tab, tableRows: TableRows()).statusMessage == "Processed: 1 GB")
    }

    @Test("Display row count defaults to the loaded count")
    func displayCountDefaultsToLoaded() {
        let snapshot = makeSnapshot(rowCount: 42)
        #expect(snapshot.displayRowCount == 42)
        #expect(!snapshot.isValueFiltered)
    }
}
