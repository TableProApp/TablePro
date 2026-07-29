//
//  StatusBarSnapshotTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("StatusBarSnapshot")
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

    @Test("Pagination controls show when a positive total is known")
    func showsPaginationWithKnownTotal() {
        let snapshot = makeSnapshot(rowCount: 1_000, pagination: PaginationState(totalRowCount: 5_000, pageSize: 1_000))
        #expect(snapshot.showsPaginationControls)
    }

    @Test("Single page with unknown total hides pagination")
    func hidesPaginationOnSinglePage() {
        let snapshot = makeSnapshot(rowCount: 10, pagination: PaginationState(totalRowCount: nil, pageSize: 50, currentPage: 1))
        #expect(!snapshot.isPagedWithUnknownTotal)
        #expect(!snapshot.showsPaginationControls)
    }

    @Test("Page beyond the first is treated as paged with unknown total")
    func pagedWhenBeyondFirstPage() {
        let snapshot = makeSnapshot(rowCount: 50, pagination: PaginationState(totalRowCount: nil, pageSize: 50, currentPage: 2, currentOffset: 50))
        #expect(snapshot.isPagedWithUnknownTotal)
        #expect(snapshot.showsPaginationControls)
    }

    @Test("A full first page with unknown total is treated as paged")
    func pagedWhenFirstPageIsFull() {
        let snapshot = makeSnapshot(rowCount: 50, pagination: PaginationState(totalRowCount: nil, pageSize: 50, currentPage: 1))
        #expect(snapshot.isPagedWithUnknownTotal)
    }

    @Test("No rows reports an empty state")
    func rowInfoNoRows() {
        let snapshot = makeSnapshot(rowCount: 0)
        #expect(snapshot.rowInfoText(selectedCount: 0) == String(localized: "No rows"))
    }

    @Test("Selecting every loaded row reports the all-selected text")
    func rowInfoAllSelected() {
        let snapshot = makeSnapshot(rowCount: 5)
        #expect(snapshot.rowInfoText(selectedCount: 5) == String(format: String(localized: "All %d rows selected"), 5))
    }

    @Test("Selecting some rows reports the partial-selection text")
    func rowInfoPartialSelection() {
        let snapshot = makeSnapshot(rowCount: 5)
        #expect(snapshot.rowInfoText(selectedCount: 2) == String(format: String(localized: "%d of %d rows selected"), 2, 5))
    }

    @Test("A table with a known total reports the offset range")
    func rowInfoTableRange() {
        let snapshot = makeSnapshot(
            rowCount: 1_000,
            pagination: PaginationState(totalRowCount: 5_000, pageSize: 1_000, currentPage: 3, currentOffset: 2_000)
        )
        let text = snapshot.rowInfoText(selectedCount: 0)
        #expect(text.contains("2001-3000"))
    }

    @Test("A paged table with unknown total reports a question mark for the total")
    func rowInfoUnknownTotalRange() {
        let snapshot = makeSnapshot(
            rowCount: 50,
            pagination: PaginationState(totalRowCount: nil, pageSize: 50, currentPage: 2, currentOffset: 50)
        )
        let text = snapshot.rowInfoText(selectedCount: 0)
        #expect(text.contains("51-100"))
        #expect(text.contains("?"))
    }

    @Test("A truncated query reports the showing-rows text")
    func rowInfoTruncatedQuery() {
        var pagination = PaginationState(pageSize: 1_000)
        pagination.hasMoreRows = true
        let snapshot = makeSnapshot(tabType: .query, rowCount: 1_000, pagination: pagination)
        let text = snapshot.rowInfoText(selectedCount: 0)
        #expect(text.contains("1,000") || text.contains("1000"))
    }
}
