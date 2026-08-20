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

    @Test("Display row count defaults to the loaded count")
    func displayCountDefaultsToLoaded() {
        let snapshot = makeSnapshot(rowCount: 42)
        #expect(snapshot.displayRowCount == 42)
        #expect(!snapshot.isValueFiltered)
    }
}
