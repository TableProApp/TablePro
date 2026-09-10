//
//  FindMatcherTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("FindMatcher")
struct FindMatcherTests {
    private let grid: [[String?]] = [
        ["active", "Alice", nil],
        ["inactive", "Bob", "note"],
        ["ACTIVE", "Chloé", "other"],
    ]

    private func cellText(_ row: Int, _ column: Int) -> String? {
        guard row >= 0, row < grid.count, column >= 0, column < grid[row].count else { return nil }
        return grid[row][column]
    }

    private func run(term: String, searchable: @escaping (Int) -> Bool = { _ in true }) -> [FindMatch] {
        FindMatcher.matches(
            term: term,
            displayRowCount: grid.count,
            columnCount: 3,
            isColumnSearchable: searchable,
            cellText: cellText
        )
    }

    @Test("finds every occurrence in row-major order")
    func rowMajorOrder() {
        let matches = run(term: "active")
        #expect(matches == [
            FindMatch(displayRow: 0, columnIndex: 0),
            FindMatch(displayRow: 1, columnIndex: 0),
            FindMatch(displayRow: 2, columnIndex: 0),
        ])
    }

    @Test("matching ignores case")
    func caseInsensitive() {
        #expect(run(term: "ACTIVE").count == 3)
        #expect(run(term: "aCtIvE").count == 3)
    }

    @Test("matching ignores diacritics")
    func diacriticInsensitive() {
        #expect(run(term: "chloe") == [FindMatch(displayRow: 2, columnIndex: 1)])
    }

    @Test("a nil cell never matches")
    func nilCellsSkipped() {
        #expect(run(term: "note") == [FindMatch(displayRow: 1, columnIndex: 2)])
    }

    @Test("an excluded column is never searched")
    func excludedColumn() {
        let matches = run(term: "active", searchable: { $0 != 0 })
        #expect(matches.isEmpty)
    }

    @Test("an empty or whitespace term matches nothing")
    func emptyTerm() {
        #expect(run(term: "").isEmpty)
        #expect(run(term: "   ").isEmpty)
    }

    @Test("binary column types are not searchable, everything else is")
    func searchableColumnTypes() {
        #expect(FindMatcher.isSearchable(.blob(rawType: "BLOB")) == false)
        #expect(FindMatcher.isSearchable(.spatial(rawType: "GEOMETRY")) == false)
        #expect(FindMatcher.isSearchable(.text(rawType: "VARCHAR")))
        #expect(FindMatcher.isSearchable(.integer(rawType: "INT")))
        #expect(FindMatcher.isSearchable(.timestamp(rawType: "TIMESTAMP")))
        #expect(FindMatcher.isSearchable(.json(rawType: "JSON")))
        #expect(FindMatcher.isSearchable(nil))
    }

    @Test("a binary column showing characters is searchable, one showing hex is not")
    func searchableBinaryFollowsItsDisplayFormat() {
        let blob = ColumnType.blob(rawType: "VARBINARY(255)")

        #expect(FindMatcher.isSearchable(blob, displayFormat: .text))
        #expect(FindMatcher.isSearchable(blob, displayFormat: .uuid))
        #expect(FindMatcher.isSearchable(blob, displayFormat: .raw) == false)
        #expect(FindMatcher.isSearchable(blob, displayFormat: nil) == false)
        #expect(FindMatcher.isSearchable(.spatial(rawType: "GEOMETRY"), displayFormat: .text) == false)
    }

    @Test("the nearest match to a display row is the first at or after it")
    func nearestMatch() {
        let matches = [
            FindMatch(displayRow: 1, columnIndex: 0),
            FindMatch(displayRow: 4, columnIndex: 0),
            FindMatch(displayRow: 9, columnIndex: 0),
        ]
        #expect(FindMatcher.nearestMatchIndex(to: 0, in: matches) == 0)
        #expect(FindMatcher.nearestMatchIndex(to: 4, in: matches) == 1)
        #expect(FindMatcher.nearestMatchIndex(to: 5, in: matches) == 2)
        #expect(FindMatcher.nearestMatchIndex(to: 99, in: matches) == 0)
        #expect(FindMatcher.nearestMatchIndex(to: 0, in: []) == nil)
    }
}

@Suite("TabFindState")
struct TabFindStateTests {
    private func state(matchCount: Int) -> TabFindState {
        var value = TabFindState(isVisible: true)
        value.term = "x"
        value.matches = (0 ..< matchCount).map { FindMatch(displayRow: $0, columnIndex: 0) }
        return value
    }

    @Test("stepping forward wraps around")
    func stepForwardWraps() {
        var value = state(matchCount: 3)
        value.stepForward()
        #expect(value.currentMatchIndex == 0)
        value.stepForward()
        #expect(value.currentMatchIndex == 1)
        value.currentMatchIndex = 2
        value.stepForward()
        #expect(value.currentMatchIndex == 0)
    }

    @Test("stepping backward from no selection lands on the last match")
    func stepBackwardWraps() {
        var value = state(matchCount: 3)
        value.stepBackward()
        #expect(value.currentMatchIndex == 2)
        value.stepBackward()
        #expect(value.currentMatchIndex == 1)
    }

    @Test("stepping with no matches does nothing")
    func stepWithoutMatches() {
        var value = state(matchCount: 0)
        value.stepForward()
        #expect(value.currentMatchIndex == nil)
        value.stepBackward()
        #expect(value.currentMatchIndex == nil)
    }

    @Test("escalation is offered only when rows are unloaded and a term is set")
    func escalationAvailability() {
        var value = TabFindState(isVisible: true)
        value.scope = .pageOfMore
        #expect(value.canEscalateToAllRows == false)
        value.term = "abc"
        #expect(value.canEscalateToAllRows)
        value.scope = .allRowsLoaded
        #expect(value.canEscalateToAllRows == false)
    }

    @Test("clearing matches drops the current index too")
    func clearMatches() {
        var value = state(matchCount: 3)
        value.currentMatchIndex = 2
        value.clearMatches()
        #expect(value.matches.isEmpty)
        #expect(value.currentMatchIndex == nil)
        #expect(value.currentMatch == nil)
    }
}

/// The find bar renders only on table tabs, and a table tab pages through `currentPage`, never
/// through `hasMoreRows`, which is the query-tab truncation flag. Reading the wrong one made every
/// table tab report its page as the whole table.
@Suite("FindScopeFromPagination")
struct FindScopeFromPaginationTests {
    private func hasUnloadedRows(_ state: PaginationState, loadedRowCount: Int) -> Bool {
        state.hasMoreRows || state.canGoToNextPage(loadedRowCount: loadedRowCount)
    }

    @Test("page 1 of a multi-page table has unloaded rows even though hasMoreRows is false")
    func firstPageOfManyIsPaged() {
        var state = PaginationState(pageSize: 1_000)
        state.totalRowCount = 12_000
        state.currentPage = 1
        #expect(state.hasMoreRows == false)
        #expect(hasUnloadedRows(state, loadedRowCount: 1_000))
    }

    @Test("the last page of a table has everything loaded")
    func lastPageIsComplete() {
        var state = PaginationState(pageSize: 1_000)
        state.totalRowCount = 1_500
        state.currentPage = 2
        #expect(hasUnloadedRows(state, loadedRowCount: 500) == false)
    }

    @Test("a table that fits on one page has everything loaded")
    func singlePageIsComplete() {
        var state = PaginationState(pageSize: 1_000)
        state.totalRowCount = 40
        state.currentPage = 1
        #expect(hasUnloadedRows(state, loadedRowCount: 40) == false)
    }

    @Test("an unknown row count with a full page is treated as paged, not as complete")
    func unknownCountWithFullPage() {
        var state = PaginationState(pageSize: 1_000)
        state.totalRowCount = nil
        state.currentPage = 1
        #expect(hasUnloadedRows(state, loadedRowCount: 1_000))
        #expect(hasUnloadedRows(state, loadedRowCount: 200) == false)
    }

    @Test("a truncated query result still counts as paged")
    func truncatedQueryResult() {
        var state = PaginationState(pageSize: 1_000)
        state.hasMoreRows = true
        #expect(hasUnloadedRows(state, loadedRowCount: 10))
    }
}

@Suite("FindCounterText")
struct FindCounterTextTests {
    @Test("a paged result always names its scope")
    func pagedCounter() {
        let text = FindCounterText.text(matchCount: 12, currentIndex: 2, scope: .pageOfMore)
        #expect(text.contains("3"))
        #expect(text.contains("12"))
        #expect(text.lowercased().contains("page"))
    }

    @Test("a fully loaded result does not claim a page")
    func loadedCounter() {
        let text = FindCounterText.text(matchCount: 12, currentIndex: 2, scope: .allRowsLoaded)
        #expect(text.contains("3"))
        #expect(text.contains("12"))
        #expect(text.lowercased().contains("page") == false)
    }

    @Test("zero matches on a paged table never reads as an answer about the whole table")
    func pagedEmptyCounter() {
        let text = FindCounterText.text(matchCount: 0, currentIndex: nil, scope: .pageOfMore)
        #expect(text.lowercased().contains("page"))
        #expect(text == String(localized: "Not on this page"))
    }

    @Test("zero matches with everything loaded is a real answer")
    func loadedEmptyCounter() {
        let text = FindCounterText.text(matchCount: 0, currentIndex: nil, scope: .allRowsLoaded)
        #expect(text == String(localized: "No matches"))
    }
}
