//
//  DataGridView+CellPaste.swift
//  TablePro
//

import AppKit

extension TableViewCoordinator {
    /// Splitting the clipboard into a cell block costs a pass over the whole string, and menu
    /// validation asks for it on every Command+V and every time the Edit menu opens. A SQL dump can
    /// be millions of characters on one line, so anything past this is not treated as a cell block
    /// and goes to row paste instead. The cap applies to the check and to the paste alike, so the
    /// menu item never promises something the handler will refuse.
    static let maxCellPasteLength = 1_000_000

    /// Whether a paste would land in the focused cell rather than append rows. Answered without
    /// mutating anything so menu validation can ask it.
    func canPasteCellsFromClipboard(anchorRow: Int, anchorColumn: Int) -> Bool {
        cellPasteGrid(anchorRow: anchorRow, anchorColumn: anchorColumn) != nil
    }

    func pasteCellsFromClipboard(anchorRow: Int, anchorColumn: Int) -> Bool {
        guard let grid = cellPasteGrid(anchorRow: anchorRow, anchorColumn: anchorColumn) else {
            return false
        }

        let dataColumnCount = tableRowsProvider().columns.count
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

    /// The clipboard as a cell block, or nil when it belongs to the row-paste path instead.
    ///
    /// A clipboard holding one value fills the focused cell, which is what copying a cell and
    /// pasting it into another cell has to mean. It used to be rejected here and fell through to
    /// row paste, which appended a row and left the focused cell untouched. A block as wide as the
    /// table is still whole rows and stays with row paste, and so is anything TablePro's own row
    /// copy wrote, which carries its own pasteboard type.
    private func cellPasteGrid(anchorRow: Int, anchorColumn: Int) -> [[String]]? {
        guard isEditable else { return nil }
        if ClipboardService.shared.hasGridRows { return nil }
        guard let text = ClipboardService.shared.readText(), !text.isEmpty else { return nil }
        guard (text as NSString).length <= Self.maxCellPasteLength else { return nil }

        let grid = text.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
        guard let firstRow = grid.first else { return nil }

        let isSingleValue = grid.count == 1 && firstRow.count == 1
        let dataColumnCount = tableRowsProvider().columns.count
        if !isSingleValue, dataColumnCount > 0, grid.allSatisfy({ $0.count == dataColumnCount }) {
            return nil
        }

        let maxRow = min(anchorRow + grid.count, cachedRowCount)
        let maxCol = min(anchorColumn + firstRow.count, dataColumnCount)
        guard anchorRow < maxRow, anchorColumn < maxCol else { return nil }

        return grid
    }
}
