//
//  PaginationStateDisplayTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("PaginationState Display")
struct PaginationStateDisplayTests {
    @Test("A known total reports the offset range")
    func rangeWithKnownTotal() {
        let pagination = PaginationState(totalRowCount: 5_000, pageSize: 1_000, currentPage: 3, currentOffset: 2_000)
        let text = pagination.rangeText(loadedRowCount: 1_000)
        #expect(text?.contains("2001-3000") == true)
        #expect(text?.contains("5,000") == true || text?.contains("5.000") == true)
    }

    @Test("An approximate total is prefixed with a tilde")
    func rangeWithApproximateTotal() {
        var pagination = PaginationState(totalRowCount: 111_559, pageSize: 1_000, currentPage: 1, currentOffset: 0)
        pagination.isApproximateRowCount = true
        let text = pagination.rangeText(loadedRowCount: 1_000)
        #expect(text?.contains("~") == true)
    }

    @Test("An exact total has no tilde")
    func rangeWithExactTotal() {
        let pagination = PaginationState(totalRowCount: 111_559, pageSize: 1_000, currentPage: 1, currentOffset: 0)
        let text = pagination.rangeText(loadedRowCount: 1_000)
        #expect(text?.contains("~") == false)
    }

    @Test("A paged table with unknown total reports a question mark")
    func rangeWithUnknownTotal() {
        let pagination = PaginationState(totalRowCount: nil, pageSize: 50, currentPage: 2, currentOffset: 50)
        let text = pagination.rangeText(loadedRowCount: 50)
        #expect(text?.contains("51-100") == true)
        #expect(text?.contains("?") == true)
    }

    @Test("A small single page has no range")
    func rangeOnSinglePage() {
        let pagination = PaginationState(totalRowCount: nil, pageSize: 50, currentPage: 1, currentOffset: 0)
        #expect(pagination.rangeText(loadedRowCount: 5) == nil)
    }

    @Test("Page size labels never use a grouping separator")
    func pageSizeLabelHasNoGrouping() {
        for size in [5, 100, 1_000, 100_000] {
            let label = PaginationState.pageSizeLabel(size)
            #expect(!label.contains(","))
            #expect(!label.contains("."))
            #expect(!label.contains(" "))
        }
    }
}
