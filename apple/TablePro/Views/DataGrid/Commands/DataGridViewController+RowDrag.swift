//
//  DataGridViewController+RowDrag.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension DataGridViewController {
    // Dropped in another app a row is a copy, as tab-separated text and an HTML table; the reorder type rides along
    // only where a reorder can run.
    func rowDragPasteboardItem(forRow row: Int) -> NSPasteboardItem? {
        guard let rowModel = model.row(at: row) else { return nil }
        let rows = model.rows
        let projection = gridCommands.visibleProjection
        // A drag cannot wait for a read, so a value left on the server says so, as text even in a binary column.
        var values = Array(rowModel.values)
        var columnTypes = rows.columnTypes
        for (column, byteCount) in rows.unloadedColumns(of: rowModel.id) where values.indices.contains(column) {
            values[column] = .text(UnloadedValueText.notLoaded(byteCount: byteCount))
            if columnTypes.indices.contains(column) { columnTypes[column] = .text(rawType: nil) }
        }
        let formatted = DataGridCommands.formatRowValues(
            projection.values(values),
            columnTypes: projection.columnTypes(columnTypes)
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
