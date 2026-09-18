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
            isMultiSort: false,
            firstClickDirection: .ascending
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
            isMultiSort: false,
            firstClickDirection: .ascending
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
            isMultiSort: false,
            firstClickDirection: .ascending
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
            isMultiSort: false,
            firstClickDirection: .ascending
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
            isMultiSort: false,
            firstClickDirection: .ascending
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
            isMultiSort: false,
            firstClickDirection: .ascending
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
            isMultiSort: true,
            firstClickDirection: .ascending
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
            isMultiSort: true,
            firstClickDirection: .ascending
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
            isMultiSort: true,
            firstClickDirection: .ascending
        )
        #expect(transition.newState.columns == [SortColumn(columnIndex: 1, direction: .ascending)])
    }

    @Test("Shift-click on empty state adds ascending")
    func shiftClickEmptyAddsAscending() {
        let transition = HeaderSortCycle.nextTransition(
            state: SortState(),
            clickedColumn: 0,
            isMultiSort: true,
            firstClickDirection: .ascending
        )
        #expect(transition.newState.columns == [SortColumn(columnIndex: 0, direction: .ascending)])
    }

    @Test("Shift-click cycle: add then toggle then remove preserves siblings")
    func shiftClickFullCyclePreservesSiblings() {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: 1, direction: .ascending)]

        let added = HeaderSortCycle.nextTransition(
            state: state, clickedColumn: 5, isMultiSort: true, firstClickDirection: .ascending
        )
        #expect(added.newState.columns == [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 5, direction: .ascending)
        ])

        let toggled = HeaderSortCycle.nextTransition(
            state: added.newState, clickedColumn: 5, isMultiSort: true, firstClickDirection: .ascending
        )
        #expect(toggled.newState.columns == [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 5, direction: .descending)
        ])

        let removed = HeaderSortCycle.nextTransition(
            state: toggled.newState, clickedColumn: 5, isMultiSort: true, firstClickDirection: .ascending
        )
        #expect(removed.newState.columns == [SortColumn(columnIndex: 1, direction: .ascending)])
    }
}

@Suite("HeaderSortCycle - source and first-click direction")
struct HeaderSortCycleSourceTests {
    @Test("A default sort's first click reverses it, and the result is the user's")
    func defaultSortFirstClickReverses() {
        let state = SortState(
            columns: [SortColumn(columnIndex: 0, direction: .ascending)],
            source: .defaultSort
        )
        let transition = HeaderSortCycle.nextTransition(
            state: state, clickedColumn: 0, isMultiSort: false, firstClickDirection: .ascending
        )
        #expect(transition.newState.columns == [SortColumn(columnIndex: 0, direction: .descending)])
        #expect(transition.newState.source == .user)
    }

    @Test("Clearing a sort by clicking is the user's empty state, never unset")
    func clearingStampsUser() {
        let state = SortState(
            columns: [SortColumn(columnIndex: 2, direction: .descending)],
            source: .user
        )
        let transition = HeaderSortCycle.nextTransition(
            state: state, clickedColumn: 2, isMultiSort: false, firstClickDirection: .ascending
        )
        #expect(transition.newState.columns.isEmpty)
        #expect(transition.newState.source == .user)
    }

    @Test("A shift-click on a default sort becomes the user's, so the tab stops being reusable")
    func shiftClickPromotesDefaultToUser() {
        let state = SortState(
            columns: [SortColumn(columnIndex: 0, direction: .ascending)],
            source: .defaultSort
        )
        let transition = HeaderSortCycle.nextTransition(
            state: state, clickedColumn: 3, isMultiSort: true, firstClickDirection: .ascending
        )
        #expect(transition.newState.columns.map(\.columnIndex) == [0, 3])
        #expect(transition.newState.source == .user)
    }

    @Test("A descending first-click direction reverses the whole cycle")
    func descendingFirstClickDirection() {
        let first = HeaderSortCycle.nextTransition(
            state: SortState(), clickedColumn: 1, isMultiSort: false, firstClickDirection: .descending
        )
        #expect(first.newState.columns == [SortColumn(columnIndex: 1, direction: .descending)])

        let second = HeaderSortCycle.nextTransition(
            state: first.newState, clickedColumn: 1, isMultiSort: false, firstClickDirection: .descending
        )
        #expect(second.newState.columns == [SortColumn(columnIndex: 1, direction: .ascending)])

        let third = HeaderSortCycle.nextTransition(
            state: second.newState, clickedColumn: 1, isMultiSort: false, firstClickDirection: .descending
        )
        #expect(third.newState.columns.isEmpty)
    }

    @Test("A descending shift-click adds, toggles, then removes")
    func descendingMultiSortCycle() {
        let base = SortState(columns: [SortColumn(columnIndex: 0, direction: .descending)], source: .user)
        let added = HeaderSortCycle.nextTransition(
            state: base, clickedColumn: 2, isMultiSort: true, firstClickDirection: .descending
        )
        #expect(added.newState.columns.map(\.direction) == [.descending, .descending])

        let toggled = HeaderSortCycle.nextTransition(
            state: added.newState, clickedColumn: 2, isMultiSort: true, firstClickDirection: .descending
        )
        #expect(toggled.newState.columns.map(\.direction) == [.descending, .ascending])

        let removed = HeaderSortCycle.nextTransition(
            state: toggled.newState, clickedColumn: 2, isMultiSort: true, firstClickDirection: .descending
        )
        #expect(removed.newState.columns.map(\.columnIndex) == [0])
    }
}
