//
//  TableRowsSorting.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Orders a result the app already holds in full, for a grid with no query to re-run.
///
/// Every other grid sorts by asking the server again, which is what a paginated table needs: the
/// first page of a sorted table is not the first page re-ordered. A result read in full has no
/// second page and, in the agent result pane, no connection to ask, so it sorts here. The
/// comparison is `RowSortComparator`, the same one the server-backed path's fallbacks use, so an
/// integer column orders numerically rather than as text.
internal enum TableRowsSorting {
    internal static func sorted(_ rows: TableRows, by state: SortState) -> TableRows {
        let ordering = state.columns.filter { rows.columns.indices.contains($0.columnIndex) }
        guard !ordering.isEmpty, rows.rows.count > 1 else { return rows }

        let ordered = rows.rows.enumerated().sorted { lhs, rhs in
            for column in ordering {
                let index = column.columnIndex
                let comparison = RowSortComparator.compare(
                    lhs.element[index].sortKey,
                    rhs.element[index].sortKey,
                    columnType: rows.columnTypes.indices.contains(index) ? rows.columnTypes[index] : nil
                )
                guard comparison != .orderedSame else { continue }
                return column.direction == .ascending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }
            return lhs.offset < rhs.offset
        }

        var result = rows
        result.reorderRows(ContiguousArray(ordered.map(\.element)))
        return result
    }

    /// The rows back in the order they arrived, which is what clearing a sort shows. Every fetched row carries its
    /// arrival position in its id; a row added since has none and keeps its place after them.
    internal static func inArrivalOrder(_ rows: TableRows) -> TableRows {
        let ordered = rows.rows.enumerated().sorted { lhs, rhs in
            switch (lhs.element.id, rhs.element.id) {
            case let (.existing(left), .existing(right)):
                return left < right
            case (.existing, .inserted):
                return true
            case (.inserted, .existing):
                return false
            case (.inserted, .inserted):
                return lhs.offset < rhs.offset
            }
        }
        var result = rows
        result.reorderRows(ContiguousArray(ordered.map(\.element)))
        return result
    }
}
