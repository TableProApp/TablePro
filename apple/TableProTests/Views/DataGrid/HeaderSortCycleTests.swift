//
//  HeaderSortCycleTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct HeaderSortCycleTests {
    private func click(
        _ state: SortState,
        column: Int,
        addsKey: Bool = false,
        first: SortDirection = .ascending
    ) -> SortState {
        HeaderSortCycle.nextTransition(
            state: state,
            clickedColumn: column,
            isMultiSort: addsKey,
            firstClickDirection: first
        ).newState
    }

    // MARK: - Plain click

    @Test("A click with no sort sorts by that column in the first-click direction")
    func clickWithNoSortStarts() {
        #expect(click(SortState(), column: 2).columns == [SortColumn(columnIndex: 2, direction: .ascending)])
    }

    @Test("A click on the sorted column flips it")
    func clickOnSortedColumnFlips() {
        let ascending = SortState(columns: [SortColumn(columnIndex: 2, direction: .ascending)])
        let descending = click(ascending, column: 2)
        #expect(descending.columns == [SortColumn(columnIndex: 2, direction: .descending)])
        #expect(click(descending, column: 2).columns == [SortColumn(columnIndex: 2, direction: .ascending)])
    }

    @Test("A click never clears the sort: Don't Sort lives in the header menu")
    func clickNeverClears() {
        var state = SortState()
        for _ in 0..<4 {
            state = click(state, column: 1)
            #expect(state.columns.count == 1)
        }
    }

    @Test("A click on another column replaces the sort with that column")
    func clickOnOtherColumnReplaces() {
        let state = SortState(columns: [SortColumn(columnIndex: 1, direction: .descending)])
        #expect(click(state, column: 4).columns == [SortColumn(columnIndex: 4, direction: .ascending)])
    }

    @Test("A click on the primary key flips it and drops the secondary keys")
    func clickOnPrimaryDropsSecondaries() {
        let state = SortState(columns: [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .descending),
        ])
        #expect(click(state, column: 1).columns == [SortColumn(columnIndex: 1, direction: .descending)])
    }

    @Test("A click on a secondary key makes it the only key")
    func clickOnSecondaryReplaces() {
        let state = SortState(columns: [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .descending),
        ])
        #expect(click(state, column: 3).columns == [SortColumn(columnIndex: 3, direction: .ascending)])
    }

    @Test("A descending first-click direction starts descending and flips to ascending")
    func descendingFirstClickDirection() {
        let first = click(SortState(), column: 1, first: .descending)
        #expect(first.columns == [SortColumn(columnIndex: 1, direction: .descending)])
        #expect(click(first, column: 1, first: .descending).columns == [SortColumn(columnIndex: 1, direction: .ascending)])
    }

    // MARK: - Option-click

    @Test("Option-click on an unsorted column appends it")
    func optionClickAppends() {
        let state = SortState(columns: [SortColumn(columnIndex: 1, direction: .ascending)])
        #expect(click(state, column: 3, addsKey: true).columns == [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .ascending),
        ])
    }

    @Test("Option-click with no sort adds the first key")
    func optionClickOnEmptyAdds() {
        #expect(click(SortState(), column: 0, addsKey: true).columns == [SortColumn(columnIndex: 0, direction: .ascending)])
    }

    @Test("Option-click on a key flips it in place and keeps the others")
    func optionClickFlipsInPlace() {
        let state = SortState(columns: [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .ascending),
        ])
        let flipped = click(state, column: 3, addsKey: true)
        #expect(flipped.columns == [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .descending),
        ])
        #expect(click(flipped, column: 3, addsKey: true).columns == [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .ascending),
        ])
    }

    @Test("Option-click on the primary key flips it and keeps the secondary")
    func optionClickOnPrimaryKeepsSecondary() {
        let state = SortState(columns: [
            SortColumn(columnIndex: 1, direction: .ascending),
            SortColumn(columnIndex: 3, direction: .descending),
        ])
        #expect(click(state, column: 1, addsKey: true).columns == [
            SortColumn(columnIndex: 1, direction: .descending),
            SortColumn(columnIndex: 3, direction: .descending),
        ])
    }

    @Test("A descending first-click direction appends descending keys")
    func descendingOptionClickAppends() {
        let base = SortState(columns: [SortColumn(columnIndex: 0, direction: .descending)], source: .user)
        let added = click(base, column: 2, addsKey: true, first: .descending)
        #expect(added.columns.map { $0.direction } == [.descending, .descending])
        #expect(click(added, column: 2, addsKey: true, first: .descending).columns.map { $0.direction } == [.descending, .ascending])
    }

    // MARK: - Source

    @Test("A click on a default sort flips it and the result is the user's")
    func defaultSortClickBecomesUsers() {
        let state = SortState(columns: [SortColumn(columnIndex: 0, direction: .ascending)], source: .defaultSort)
        let next = click(state, column: 0)
        #expect(next.columns == [SortColumn(columnIndex: 0, direction: .descending)])
        #expect(next.source == .user)
    }

    @Test("An Option-click on a default sort becomes the user's")
    func optionClickPromotesDefaultToUser() {
        let state = SortState(columns: [SortColumn(columnIndex: 0, direction: .ascending)], source: .defaultSort)
        let next = click(state, column: 3, addsKey: true)
        #expect(next.columns.map { $0.columnIndex } == [0, 3])
        #expect(next.source == .user)
    }

    @Test("A click from an unset sort is the user's")
    func unsetBecomesUsers() {
        #expect(click(SortState(), column: 1).source == .user)
        #expect(click(SortState(), column: 1, addsKey: true).source == .user)
    }
}
