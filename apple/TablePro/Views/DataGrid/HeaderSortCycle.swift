//
//  HeaderSortCycle.swift
//  TablePro
//

import Foundation

struct HeaderSortTransition: Equatable {
    let newState: SortState
}

// HIG sorting: a click sorts by the column, a click on the sorted column flips it, Option-click adds or flips a
// secondary key. Don't Sort lives in the header menu. Every result is stamped .user so the app default never overwrites it.
enum HeaderSortCycle {
    static func nextTransition(
        state: SortState,
        clickedColumn: Int,
        isMultiSort: Bool,
        firstClickDirection: SortDirection
    ) -> HeaderSortTransition {
        var next = isMultiSort
            ? addingKey(state: state, clickedColumn: clickedColumn, firstClickDirection: firstClickDirection)
            : replacingSort(state: state, clickedColumn: clickedColumn, firstClickDirection: firstClickDirection)
        next.source = .user
        return HeaderSortTransition(newState: next)
    }

    private static func addingKey(state: SortState, clickedColumn: Int, firstClickDirection: SortDirection) -> SortState {
        var next = state
        guard let index = state.columns.firstIndex(where: { $0.columnIndex == clickedColumn }) else {
            next.columns.append(SortColumn(columnIndex: clickedColumn, direction: firstClickDirection))
            return next
        }
        next.columns[index].direction = state.columns[index].direction.opposite
        return next
    }

    private static func replacingSort(state: SortState, clickedColumn: Int, firstClickDirection: SortDirection) -> SortState {
        guard let primary = state.columns.first, primary.columnIndex == clickedColumn else {
            return SortState(columns: [SortColumn(columnIndex: clickedColumn, direction: firstClickDirection)])
        }
        var flipped = primary
        flipped.direction = primary.direction.opposite
        return SortState(columns: [flipped])
    }
}
