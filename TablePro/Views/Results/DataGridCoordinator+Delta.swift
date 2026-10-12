//
//  DataGridCoordinator+Delta.swift
//  TablePro
//

import AppKit

internal extension TableViewCoordinator {
    func applyDelta(_ delta: Delta) {
        switch delta {
        case .cellChanged(let row, let column):
            selectionSummaryTracker.dataDidChange()
            guard let tableView,
                  let tableColumn = tableColumnIndex(for: column)
            else { return }
            guard row >= 0, row < tableView.numberOfRows else { return }
            invalidateDisplayCache(forDisplayRow: row, column: column)
            updateVisualIndex(forDisplayRow: row)
            redrawCells(rows: IndexSet(integer: row), tableColumnIndexes: IndexSet(integer: tableColumn))
            invalidateRowDecoration(displayRow: row)
        case .cellsChanged(let positions):
            guard !positions.isEmpty else { return }
            selectionSummaryTracker.dataDidChange()
            guard let tableView else { return }
            var rowSet = IndexSet()
            var colSet = IndexSet()
            for position in positions {
                if position.row >= 0, position.row < tableView.numberOfRows {
                    rowSet.insert(position.row)
                }
                if let tableColumn = tableColumnIndex(for: position.column) {
                    colSet.insert(tableColumn)
                }
                invalidateDisplayCache(forDisplayRow: position.row, column: position.column)
            }
            guard !rowSet.isEmpty, !colSet.isEmpty else { return }
            for row in rowSet {
                updateVisualIndex(forDisplayRow: row)
            }
            redrawCells(rows: rowSet, tableColumnIndexes: colSet)
            for row in rowSet {
                invalidateRowDecoration(displayRow: row)
            }
        case .rowsInserted(let indices):
            guard !indices.isEmpty else { return }
            overlayEditor?.dismiss(commit: false)
            overlayViewer?.dismiss()
            dismissPopoversBoundToDisplayPositions()
            applyInsertedRows(indices)
        case .rowsRemoved(let indices):
            guard !indices.isEmpty else { return }
            overlayEditor?.dismiss(commit: false)
            overlayViewer?.dismiss()
            dismissPopoversBoundToDisplayPositions()
            applyRemovedRows(indices)
        case .columnsReplaced, .fullReplace:
            applyFullReplace()
        }
    }

    /// A value filter decides afresh which rows are shown, so the cell selection cannot follow its
    /// rows there and is dropped instead of shifted.
    func applyInsertedRows(_ indices: IndexSet) {
        selectionSummaryTracker.dataDidChange()
        guard let tableView else { return }
        if valueFilterState.isActive {
            selectionController.clear()
            reloadAfterRowMutationWithValueFilter()
            return
        }
        visualIndex.rebuild(from: changeManager)
        updateCache()
        let keyTableView = tableView as? KeyHandlingTableView
        let focusedRow = keyTableView?.focusedRow ?? -1
        tableView.insertRows(at: indices, withAnimation: Self.rowAnimation(.slideDown))
        selectionController.applyInsertedRows(indices, newRowCount: cachedRowCount)
        /// AppKit shifts the selected rows without posting a selection change, so nothing else moves
        /// the cursor with them.
        keyTableView?.focusedRow = GridSelection.row(focusedRow, afterInserting: indices)
        repaintVisibleRowDecorations()
    }

    /// Accessibility > Display > Reduce Motion asks for no sliding rows, and the app
    /// already honours it elsewhere.
    static func rowAnimation(_ preferred: NSTableView.AnimationOptions) -> NSTableView.AnimationOptions {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? [] : preferred
    }

    func applyRemovedRows(_ indices: IndexSet) {
        selectionSummaryTracker.dataDidChange()
        guard let tableView else { return }
        if valueFilterState.isActive {
            selectionController.clear()
            reloadAfterRowMutationWithValueFilter()
            return
        }
        visualIndex.rebuild(from: changeManager)
        updateCache()
        let keyTableView = tableView as? KeyHandlingTableView
        let focusedRow = keyTableView?.focusedRow ?? -1
        tableView.removeRows(at: indices, withAnimation: Self.rowAnimation(.slideUp))
        selectionController.applyRemovedRows(indices, newRowCount: cachedRowCount)
        keyTableView?.focusedRow = GridSelection.row(focusedRow, afterRemoving: indices) ?? -1
        repaintVisibleRowDecorations()
    }

    func applyFullReplace() {
        selectionSummaryTracker.dataDidChange()
        overlayEditor?.dismiss(commit: false)
        overlayViewer?.dismiss()
        dismissPopoversBoundToDisplayPositions()
        pruneStaleValueFilters()
        guard let tableView else { return }
        invalidateAllDisplayCaches()
        recomputeValueFilteredIDs()
        updateValueFilterHeaderIndicators()
        updateCache()
        selectionController.clear()
        tableView.reloadData()
        startBackgroundPrewarm()
    }

    func invalidateCachesForUndoRedo() {
        selectionSummaryTracker.dataDidChange()
        invalidateAllDisplayCaches()
        updateCache()
        reloadVisibleRowsAndStates()
    }

    /// Repaints visible rows in the two layers a row needs: `repaintRows` covers the row-number
    /// column and the drawn cells, and `refreshVisibleRowVisualStates` then visits each live
    /// `NSTableRowView` so `applyVisualState` can carry the per-row decoration (deleted or inserted
    /// tint, deleted-row context menu state) without recreating a view. Both delegates call this
    /// after a model mutation that leaves the row count alone.
    func reloadVisibleRowsAndStates() {
        guard let tableView else { return }
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return }
        invalidateDisplayCache()
        repaintRows(IndexSet(integersIn: visibleRange.location..<(visibleRange.location + visibleRange.length)))
        refreshVisibleRowVisualStates()
        startBackgroundPrewarm()
    }

    func reloadRowAndState(at row: Int) {
        guard let tableView, row >= 0, row < tableView.numberOfRows else { return }
        invalidateDisplayCache(forDisplayRow: row)
        repaintRows(IndexSet(integer: row))
        refreshRowVisualState(at: row)
    }

    private func reloadAfterRowMutationWithValueFilter() {
        guard let tableView else { return }
        recomputeValueFilteredIDs()
        updateCache()
        visualIndex.rebuild(from: changeManager)
        tableView.reloadData()
        startBackgroundPrewarm()
    }

    private func invalidateDisplayCache(forDisplayRow displayIndex: Int) {
        guard let row = displayRow(at: displayIndex) else { return }
        displayCache.clearValues(forID: row.id)
    }

    private func invalidateDisplayCache(forDisplayRow displayIndex: Int, column: Int) {
        guard let row = displayRow(at: displayIndex) else { return }
        displayCache.clearHighlight(forID: row.id)
        guard let box = displayCache.box(forID: row.id),
              column >= 0, column < box.values.count else { return }
        box.values[column] = nil
        displayCache.setBox(box, forID: row.id)
    }
}
