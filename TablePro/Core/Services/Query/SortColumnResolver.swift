//
//  SortColumnResolver.swift
//  TablePro
//

import Foundation

/// Resolves a sort column to the name it refers to, then to a position in whichever column
/// list the consumer will read.
///
/// `SortColumn.columnIndex` is a position in the grid's result columns, but a scoped browse
/// query hands the driver a different, shorter list. Resolving the name first is what keeps
/// those two apart: a position only means something next to the list it was taken from.
enum SortColumnResolver {
    static func columnName(for sortColumn: SortColumn, displayColumns: [String]) -> String? {
        if let name = sortColumn.columnName, !name.isEmpty {
            return name
        }
        guard sortColumn.columnIndex >= 0, sortColumn.columnIndex < displayColumns.count else { return nil }
        return displayColumns[sortColumn.columnIndex]
    }

    static func columnNames(for sortState: SortState?, displayColumns: [String]) -> [String] {
        guard let sortState else { return [] }
        return sortState.columns.compactMap { columnName(for: $0, displayColumns: displayColumns) }
    }

    /// Records the name each entry refers to, so the sort survives a later change to the
    /// column list that would move or invalidate its position.
    static func stamped(_ sortState: SortState, displayColumns: [String]) -> SortState {
        var stamped = sortState
        for index in stamped.columns.indices {
            stamped.columns[index].columnName = columnName(
                for: stamped.columns[index],
                displayColumns: displayColumns
            )
        }
        return stamped
    }

    /// Re-points each entry at its column's current position. The header draws its chevron and
    /// runs its click cycle off `columnIndex`, so a stale one puts the affordance on the wrong
    /// column, or loses it, while the rows are ordered correctly.
    static func reindexed(_ sortState: SortState, displayColumns: [String]) -> SortState {
        var reindexed = sortState
        for index in reindexed.columns.indices {
            guard let name = columnName(for: reindexed.columns[index], displayColumns: displayColumns) else {
                continue
            }
            reindexed.columns[index].columnName = name
            guard let position = displayColumns.firstIndex(of: name) else { continue }
            reindexed.columns[index].columnIndex = position
        }
        return reindexed
    }

    /// The name for a clause that spells the column out. Prefers a stamped name the list still
    /// carries, then the position, so a renamed column resolves to its new name instead of an
    /// identifier the server no longer knows.
    static func clauseColumnName(for sortColumn: SortColumn, displayColumns: [String]) -> String? {
        if let name = sortColumn.columnName, displayColumns.contains(name) {
            return name
        }
        if sortColumn.columnIndex >= 0, sortColumn.columnIndex < displayColumns.count {
            return displayColumns[sortColumn.columnIndex]
        }
        return sortColumn.columnName
    }

    /// Positions into `targetColumns`, which is the list the consumer indexes into. A sort
    /// column missing from that list is dropped rather than approximated, because the nearest
    /// index is a different column and would sort by it silently.
    static func resolvedIndices(
        for sortState: SortState?,
        displayColumns: [String],
        targetColumns: [String]
    ) -> [(columnIndex: Int, ascending: Bool)] {
        guard let sortState else { return [] }
        return sortState.columns.compactMap { sortColumn in
            guard let name = columnName(for: sortColumn, displayColumns: displayColumns),
                  let index = targetColumns.firstIndex(of: name) else { return nil }
            return (index, sortColumn.direction == .ascending)
        }
    }
}
