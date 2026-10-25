//
//  DataGridViewController+RowDrag.swift
//  TablePro
//

import AppKit

extension DataGridViewController {
    // Dropped in another app a row is a copy, as tab-separated text and an HTML table; the reorder type rides along
    // only where a reorder can run.
    func rowDragPasteboardItem(forRow row: Int) -> NSPasteboardItem? {
        guard let rowModel = model.row(at: row) else { return nil }
        let rows = model.rows
        let projection = gridCommands.visibleProjection
        let formatted = DataGridCommands.formatRowValues(
            projection.values(Array(rowModel.values)),
            columnTypes: projection.columnTypes(rows.columnTypes)
        )
        let item = NSPasteboardItem()
        if model.configuration.rowReorder.isEnabled {
            item.setString(String(row), forType: Self.rowDragType)
        }
        item.setString(formatted.joined(separator: "\t"), forType: .string)
        item.setString(HtmlTableEncoder.encode(rows: [formatted], headers: projection.columns(rows.columns)), forType: .html)
        return item
    }

    // A press on the number of a selected row lifts the rows; a press anywhere else selects. Structure reorders from any row.
    func canDragRows(fromRowNumberAt row: Int) -> Bool {
        if model.configuration.rowReorder.isEnabled { return true }
        let selection = model.selection
        return gridCommands.isWholeRows(selection) && selection.affectedRows.contains(row)
    }
}
