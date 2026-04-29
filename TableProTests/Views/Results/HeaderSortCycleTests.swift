//
//  HeaderSortCycleTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("HeaderSortCycle - single column")
struct HeaderSortCycleSingleColumnTests {
    @Test("No active sort starts ascending")
    func noActiveSortStartsAscending() {
        let action = HeaderSortCycle.nextAction(
            state: SortState(),
            clickedColumn: 2,
            isMultiSort: false
        )
        #expect(action == .sort(columnIndex: 2, ascending: true, isMultiSort: false))
    }

    @Test("Ascending on this column advances to descending")
    func ascendingAdvancesToDescending() {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: 2, direction: .ascending)]
        let action = HeaderSortCycle.nextAction(
            state: state,
            clickedColumn: 2,
            isMultiSort: false
        )
        #expect(action == .sort(columnIndex: 2, ascending: false, isMultiSort: false))
    }

    @Test("Descending on this column clears the sort")
    func descendingClearsSort() {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: 2, direction: .descending)]
        let action = HeaderSortCycle.nextAction(
            state: state,
            clickedColumn: 2,
            isMultiSort: false
        )
        #expect(action == .clear)
    }

    @Test("Different column replaces primary with ascending")
    func differentColumnReplacesPrimary() {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: 1, direction: .descending)]
        let action = HeaderSortCycle.nextAction(
            state: state,
            clickedColumn: 4,
            isMultiSort: false
        )
        #expect(action == .sort(columnIndex: 4, ascending: true, isMultiSort: false))
    }

    @Test("Multi-column primary cycles independently of secondary")
    func multiColumnPrimaryCyclesIndependently() {
        var state = SortState()
        state.columns = [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .descending)
        ]
        let action = HeaderSortCycle.nextAction(
            state: state,
            clickedColumn: 1,
            isMultiSort: false
        )
        #expect(action == .sort(columnIndex: 1, ascending: false, isMultiSort: false))
    }

    @Test("Click on secondary column without shift replaces primary")
    func clickOnSecondaryWithoutShiftReplacesPrimary() {
        var state = SortState()
        state.columns = [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .descending)
        ]
        let action = HeaderSortCycle.nextAction(
            state: state,
            clickedColumn: 3,
            isMultiSort: false
        )
        #expect(action == .sort(columnIndex: 3, ascending: true, isMultiSort: false))
    }
}

@Suite("HeaderSortCycle - multi-column shift-click")
struct HeaderSortCycleMultiColumnTests {
    @Test("Shift-click on unsorted column adds it ascending")
    func shiftClickUnsortedAddsAscending() {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: 1, direction: .ascending)]
        let action = HeaderSortCycle.nextAction(
            state: state,
            clickedColumn: 3,
            isMultiSort: true
        )
        #expect(action == .sort(columnIndex: 3, ascending: true, isMultiSort: true))
    }

    @Test("Shift-click on existing column sends descending")
    func shiftClickExistingSendsDescending() {
        var state = SortState()
        state.columns = [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .ascending)
        ]
        let action = HeaderSortCycle.nextAction(
            state: state,
            clickedColumn: 3,
            isMultiSort: true
        )
        #expect(action == .sort(columnIndex: 3, ascending: false, isMultiSort: true))
    }

    @Test("Shift-click on empty state adds ascending")
    func shiftClickEmptyAddsAscending() {
        let action = HeaderSortCycle.nextAction(
            state: SortState(),
            clickedColumn: 0,
            isMultiSort: true
        )
        #expect(action == .sort(columnIndex: 0, ascending: true, isMultiSort: true))
    }
}
