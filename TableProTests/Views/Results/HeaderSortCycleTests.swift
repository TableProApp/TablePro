//
//  HeaderSortCycleTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("HeaderSortCycle - single column")
struct HeaderSortCycleSingleColumnTests {
    @Test("No active sort starts ascending")
    func noActiveSortStartsAscending() {
        let transition = HeaderSortCycle.nextTransition(
            state: SortState(),
            clickedColumn: 2,
            isMultiSort: false
        )
        #expect(transition.newState.columns == [SortColumn(columnIndex: 2, direction: .ascending)])
    }

    @Test("Ascending on this column advances to descending")
    func ascendingAdvancesToDescending() {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: 2, direction: .ascending)]
        let transition = HeaderSortCycle.nextTransition(
            state: state,
            clickedColumn: 2,
            isMultiSort: false
        )
        #expect(transition.newState.columns == [SortColumn(columnIndex: 2, direction: .descending)])
    }

    @Test("Descending on this column clears the sort")
    func descendingClearsSort() {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: 2, direction: .descending)]
        let transition = HeaderSortCycle.nextTransition(
            state: state,
            clickedColumn: 2,
            isMultiSort: false
        )
        #expect(transition.newState.columns.isEmpty)
    }

    @Test("Different column replaces primary with ascending")
    func differentColumnReplacesPrimary() {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: 1, direction: .descending)]
        let transition = HeaderSortCycle.nextTransition(
            state: state,
            clickedColumn: 4,
            isMultiSort: false
        )
        #expect(transition.newState.columns == [SortColumn(columnIndex: 4, direction: .ascending)])
    }

    @Test("Multi-column primary cycles independently of secondary")
    func multiColumnPrimaryCyclesIndependently() {
        var state = SortState()
        state.columns = [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .descending)
        ]
        let transition = HeaderSortCycle.nextTransition(
            state: state,
            clickedColumn: 1,
            isMultiSort: false
        )
        #expect(transition.newState.columns == [SortColumn(columnIndex: 1, direction: .descending)])
    }

    @Test("Click on secondary column without shift replaces primary")
    func clickOnSecondaryWithoutShiftReplacesPrimary() {
        var state = SortState()
        state.columns = [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .descending)
        ]
        let transition = HeaderSortCycle.nextTransition(
            state: state,
            clickedColumn: 3,
            isMultiSort: false
        )
        #expect(transition.newState.columns == [SortColumn(columnIndex: 3, direction: .ascending)])
    }
}

@Suite("HeaderSortCycle - multi-column shift-click")
struct HeaderSortCycleMultiColumnTests {
    @Test("Shift-click on unsorted column adds it ascending")
    func shiftClickUnsortedAddsAscending() {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: 1, direction: .ascending)]
        let transition = HeaderSortCycle.nextTransition(
            state: state,
            clickedColumn: 3,
            isMultiSort: true
        )
        #expect(transition.newState.columns == [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .ascending)
        ])
    }

    @Test("Shift-click on existing ascending column toggles to descending")
    func shiftClickAscendingTogglesToDescending() {
        var state = SortState()
        state.columns = [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .ascending)
        ]
        let transition = HeaderSortCycle.nextTransition(
            state: state,
            clickedColumn: 3,
            isMultiSort: true
        )
        #expect(transition.newState.columns == [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .descending)
        ])
    }

    @Test("Shift-click on existing descending column removes it from sort")
    func shiftClickDescendingRemovesColumn() {
        var state = SortState()
        state.columns = [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .descending)
        ]
        let transition = HeaderSortCycle.nextTransition(
            state: state,
            clickedColumn: 3,
            isMultiSort: true
        )
        #expect(transition.newState.columns == [SortColumn(columnIndex: 1, direction: .ascending)])
    }

    @Test("Shift-click on empty state adds ascending")
    func shiftClickEmptyAddsAscending() {
        let transition = HeaderSortCycle.nextTransition(
            state: SortState(),
            clickedColumn: 0,
            isMultiSort: true
        )
        #expect(transition.newState.columns == [SortColumn(columnIndex: 0, direction: .ascending)])
    }

    @Test("Shift-click cycle: add then toggle then remove preserves siblings")
    func shiftClickFullCyclePreservesSiblings() {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: 1, direction: .ascending)]

        let added = HeaderSortCycle.nextTransition(state: state, clickedColumn: 5, isMultiSort: true)
        #expect(added.newState.columns == [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 5, direction: .ascending)
        ])

        let toggled = HeaderSortCycle.nextTransition(
            state: added.newState, clickedColumn: 5, isMultiSort: true
        )
        #expect(toggled.newState.columns == [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 5, direction: .descending)
        ])

        let removed = HeaderSortCycle.nextTransition(
            state: toggled.newState, clickedColumn: 5, isMultiSort: true
        )
        #expect(removed.newState.columns == [SortColumn(columnIndex: 1, direction: .ascending)])
    }
}
