//
//  DataGridView+ColumnGeometry.swift
//  TablePro
//

import AppKit

extension TableViewCoordinator {
    /// The one place a column width, order or visibility change reaches the drawn body.
    ///
    /// `NSTableView` pushes column geometry into a table body by relaying its cell views out and
    /// redrawing them. This grid mounts no view for a data column and draws every cell itself
    /// (#2381), so that channel is empty, and `NSTableRowView` has no geometry callback of its own.
    /// AppKit resizes a row view only when the table's total width moves, which it does not while
    /// the columns still fit inside the viewport, so nothing is marked dirty and the body keeps the
    /// layout it last drew until an unrelated event invalidates a row (#2449).
    ///
    /// Everything that paints from live `rect(ofColumn:)` is invalidated here: each row, the table
    /// view's own background past the last row, and the cell selection outline. A row is reached
    /// through its drawn cells, which is enough for the whole row: `canDrawSubviewsIntoLayer` makes
    /// the row's layer the one backing store for the row and its cells, so dirtying the cells marks
    /// the row itself dirty and its separators and cell-range selection wash repaint with them.
    func columnGeometryDidChange() {
        guard let tableView else { return }
        redrawVisibleCells()
        tableView.setNeedsDisplay(tableView.visibleRect)
        selectionController.overlay?.needsDisplay = true
    }

    /// Keeps the row-number column at the head of the run.
    ///
    /// `DataGridColumnPool` places every data column relative to it and reads its position off
    /// `tableColumns.first`, so a row-number column dragged into the run leaves the pool ordering
    /// from index 0 and walking it one place further right on every reconcile until it reaches the
    /// far end, permanently. No fixed position may name a data column (#2381), and this is the
    /// other half of that: the origin those positions are measured from has to hold still.
    ///
    /// A drag opens with `newColumnIndex` at -1, which asks whether the column may be reordered at
    /// all rather than proposing a destination. Answering no there stops the drag before it starts,
    /// so that probe is refused only for the row-number column itself.
    func tableView(
        _ tableView: NSTableView,
        shouldReorderColumn columnIndex: Int,
        toColumn newColumnIndex: Int
    ) -> Bool {
        guard tableView.tableColumns.indices.contains(columnIndex) else { return false }
        guard let rowNumberIndex = tableView.tableColumns.firstIndex(where: {
            $0.identifier == ColumnIdentitySchema.rowNumberIdentifier
        }) else { return true }
        guard columnIndex != rowNumberIndex else { return false }
        return newColumnIndex < 0 || newColumnIndex > rowNumberIndex
    }
}
