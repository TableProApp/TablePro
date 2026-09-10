//
//  GridSelectionRestore.swift
//  TablePro
//
//  What a remounted data grid puts back, given what its owner kept and how big the result is now.
//

import Foundation

enum GridSelectionRestore {
    struct Resolution: Equatable {
        /// The rows to hand `NSTableView`.
        ///
        /// For a cell rectangle this is the anchor row the table view actually held, not every row
        /// the rectangle covers. AppKit fills a selected row edge to edge and `DataGridRowView`
        /// skips its partial cell fill on one, so selecting the whole span would paint and navigate
        /// the reader's block as full rows, which is the widening this storage exists to avoid.
        var nativeRows: Set<Int>
        /// The rows every consumer of the selection should see, which for a rectangle is its span.
        var publishedRows: Set<Int>
        var cells: GridSelection

        static let none = Resolution(nativeRows: [], publishedRows: [], cells: .empty)

        var isEmpty: Bool { publishedRows.isEmpty && cells.isEmpty }
    }

    /// The cell rectangle wins when there is one, because it is the only one of the two that knows
    /// the whole span: a cell drag pins the table view's row selection to its anchor row.
    ///
    /// Everything is clamped to the result actually on screen. The rows can have shrunk while the
    /// grid was unmounted, and `NSTableView.selectRowIndexes` is all-or-nothing on an out-of-range
    /// member (measured), so pushing an unclamped set selects nothing at all rather than the rows
    /// that do still exist.
    ///
    /// `columnLimit` is the count of *presented data* columns, not of `tableColumns`: the latter
    /// also counts the row-number column, both spacers and every unused pool slot, so clamping
    /// against it would let a stale rectangle survive onto columns that are no longer shown.
    static func resolve(
        storedRows: Set<Int>,
        storedCells: GridSelection,
        rowLimit: Int,
        columnLimit: Int
    ) -> Resolution {
        guard rowLimit > 0 else { return .none }
        let rows = storedRows.filter { $0 >= 0 && $0 < rowLimit }
        /// Only the rectangle needs a column to land on. With every data column hidden the rows and
        /// the row-number gutter are still there and still selectable, so gating the row half on the
        /// column count too would refuse to restore a row selection that is perfectly valid.
        let cells = columnLimit > 0
            ? storedCells.clamped(rowLimit: rowLimit, columnLimit: columnLimit)
            : GridSelection.empty
        guard !cells.isEmpty else {
            return Resolution(nativeRows: rows, publishedRows: rows, cells: .empty)
        }
        return Resolution(nativeRows: rows, publishedRows: Set(cells.affectedRows), cells: cells)
    }
}
