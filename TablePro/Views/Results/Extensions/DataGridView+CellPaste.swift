//
//  DataGridView+CellPaste.swift
//  TablePro
//

import AppKit

extension TableViewCoordinator {
    func pasteCellsFromClipboard(anchorRow: Int, anchorColumn: Int) -> Bool {
        guard isEditable else { return false }
        if ClipboardService.shared.hasGridRows { return false }
        guard let text = ClipboardService.shared.readText(), !text.isEmpty else { return false }

        let grid = text.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
        guard !grid.isEmpty, grid[0].count > 1 || grid.count > 1 else { return false }

        let dataColumnCount = tableRowsProvider().columns.count
        if dataColumnCount > 0, grid.allSatisfy({ $0.count == dataColumnCount }) {
            return false
        }

        let maxRow = min(anchorRow + grid.count, cachedRowCount)
        let maxCol = min(anchorColumn + (grid.first?.count ?? 0), dataColumnCount)
        guard anchorRow < maxRow, anchorColumn < maxCol else { return false }

        let undoManager = tableView?.window?.undoManager
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName(String(localized: "Paste Cells"))

        for (gridRow, rowValues) in grid.enumerated() {
            let targetRow = anchorRow + gridRow
            guard targetRow < maxRow else { break }
            guard !changeManager.isRowDeleted(targetRow) else { continue }

            for (gridCol, cellValue) in rowValues.enumerated() {
                let targetCol = anchorColumn + gridCol
                guard targetCol < maxCol else { break }
                commitCellEdit(row: targetRow, columnIndex: targetCol, newValue: cellValue)
            }
        }

        undoManager?.endUndoGrouping()

        tableView?.reloadData()
        return true
    }
}
