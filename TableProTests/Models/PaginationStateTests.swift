//
//  PaginationStateTests.swift
//  TableProTests
//
//  Created on 2026-02-17.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Pagination State")
struct PaginationStateTests {

    @Test("Default page size is 1000")
    func defaultPageSize() {
        #expect(PaginationState.defaultPageSize == 1_000)
    }

    @Test("Total pages with nil total returns 1")
    func totalPagesWithNilTotal() {
        let state = PaginationState(totalRowCount: nil, pageSize: 100)
        #expect(state.totalPages == 1)
    }

    @Test("Total pages with zero total returns 1")
    func totalPagesWithZeroTotal() {
        let state = PaginationState(totalRowCount: 0, pageSize: 100)
        #expect(state.totalPages == 1)
    }

    @Test("Total pages with exact page boundary")
    func totalPagesExactBoundary() {
        let state = PaginationState(totalRowCount: 10, pageSize: 10)
        #expect(state.totalPages == 1)
    }

    @Test("Total pages with one row over boundary")
    func totalPagesOverBoundary() {
        let state = PaginationState(totalRowCount: 11, pageSize: 10)
        #expect(state.totalPages == 2)
    }

    @Test("Total pages with multiple pages")
    func totalPagesMultiple() {
        let state = PaginationState(totalRowCount: 100, pageSize: 10)
        #expect(state.totalPages == 10)
    }

    @Test("Has next page when on first page of multiple pages")
    func hasNextPageOnFirstPage() {
        let state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 1)
        #expect(state.hasNextPage == true)
    }

    @Test("Has no next page when on last page")
    func hasNoNextPageOnLastPage() {
        let state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 10)
        #expect(state.hasNextPage == false)
    }

    @Test("Has no previous page when on first page")
    func hasNoPreviousPageOnFirstPage() {
        let state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 1)
        #expect(state.hasPreviousPage == false)
    }

    @Test("Has previous page when on second page")
    func hasPreviousPageOnSecondPage() {
        let state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 2)
        #expect(state.hasPreviousPage == true)
    }

    @Test("Go to next page updates current page and offset")
    func goToNextPage() {
        var state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 1)
        state.goToNextPage()
        #expect(state.currentPage == 2)
        #expect(state.currentOffset == 10)
    }

    @Test("Go to previous page updates current page and offset")
    func goToPreviousPage() {
        var state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 2, currentOffset: 10)
        state.goToPreviousPage()
        #expect(state.currentPage == 1)
        #expect(state.currentOffset == 0)
    }

    @Test("Go to first page resets to page 1")
    func goToFirstPage() {
        var state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 5, currentOffset: 40)
        state.goToFirstPage()
        #expect(state.currentPage == 1)
        #expect(state.currentOffset == 0)
    }

    @Test("Go to last page navigates to final page")
    func goToLastPage() {
        var state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 1)
        state.goToLastPage()
        #expect(state.currentPage == 10)
        #expect(state.currentOffset == 90)
    }

    @Test("Go to valid page updates state")
    func goToValidPage() {
        var state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 1)
        state.goToPage(5)
        #expect(state.currentPage == 5)
        #expect(state.currentOffset == 40)
    }

    @Test("Go to invalid page zero does not update state")
    func goToInvalidPageZero() {
        var state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 1)
        state.goToPage(0)
        #expect(state.currentPage == 1)
        #expect(state.currentOffset == 0)
    }

    @Test("Go to page beyond total does not update state")
    func goToPageBeyondTotal() {
        var state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 1)
        state.goToPage(15)
        #expect(state.currentPage == 1)
        #expect(state.currentOffset == 0)
    }

    @Test("Range start calculation")
    func rangeStart() {
        let state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 2, currentOffset: 10)
        #expect(state.rangeStart == 11)
    }

    @Test("Range end calculation on middle page")
    func rangeEndMiddlePage() {
        let state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 2, currentOffset: 10)
        #expect(state.rangeEnd == 20)
    }

    @Test("Range end calculation on last page with partial data")
    func rangeEndLastPagePartial() {
        let state = PaginationState(totalRowCount: 95, pageSize: 10, currentPage: 10, currentOffset: 90)
        #expect(state.rangeEnd == 95)
    }

    @Test("Reset returns to first page")
    func reset() {
        var state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 5, currentOffset: 40)
        state.reset()
        #expect(state.currentPage == 1)
        #expect(state.currentOffset == 0)
    }

    @Test("Update page size recalculates current page")
    func updatePageSize() {
        var state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 5, currentOffset: 40)
        state.updatePageSize(20)
        #expect(state.pageSize == 20)
        #expect(state.currentPage == 3)
        #expect(state.currentOffset == 40)
    }

    @Test("Update page size ignores zero or negative values")
    func updatePageSizeIgnoresInvalid() {
        var state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 1)
        state.updatePageSize(0)
        #expect(state.pageSize == 10)
        state.updatePageSize(-5)
        #expect(state.pageSize == 10)
    }

    @Test("Update offset recalculates current page")
    func updateOffset() {
        var state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 1, currentOffset: 0)
        state.updateOffset(40)
        #expect(state.currentOffset == 40)
        #expect(state.currentPage == 5)
    }

    @Test("Update offset ignores negative values")
    func updateOffsetIgnoresNegative() {
        var state = PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 5, currentOffset: 40)
        state.updateOffset(-10)
        #expect(state.currentOffset == 40)
        #expect(state.currentPage == 5)
    }

    @Test("Single page of data")
    func singlePageData() {
        let state = PaginationState(totalRowCount: 5, pageSize: 10, currentPage: 1)
        #expect(state.totalPages == 1)
        #expect(state.hasNextPage == false)
        #expect(state.hasPreviousPage == false)
        #expect(state.rangeStart == 1)
        #expect(state.rangeEnd == 5)
    }
}
