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

    /// Fills cells rightwards from the anchor, in the order they appear on screen.
    ///
    /// The walk is over display positions, not data indices. Adding to the anchor's data index
    /// walked the result's own column order, so after a column reorder the second value landed in
    /// whichever column happens to hold the next slot rather than the one beside it on screen, and a
    /// hidden column could swallow a value with nothing shown for it.
    func pasteCellsFromClipboard(anchorRow: Int, anchorColumn: Int) -> Bool {
        guard let grid = cellPasteGrid(anchorRow: anchorRow, anchorColumn: anchorColumn),
              let anchorPosition = displayPosition(ofDataColumnIndex: anchorColumn) else {
            return false
        }

        let maxRow = min(anchorRow + grid.count, cachedRowCount)
        let maxCol = min(anchorPosition + Self.blockWidth(grid), presentedColumnCount)
        guard anchorRow < maxRow, anchorPosition < maxCol else { return false }

        let undoManager = tableView?.window?.undoManager
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName(String(localized: "Paste Cells"))

        let tableRows = tableRowsProvider()
        var refusedCell = false
        for (gridRow, rowValues) in grid.enumerated() {
            let targetRow = anchorRow + gridRow
            guard targetRow < maxRow else { break }
            guard !isRowDeleted(displayRow: targetRow) else { continue }

            for (gridCol, cellValue) in rowValues.enumerated() {
                let targetPosition = anchorPosition + gridCol
                guard targetPosition < maxCol else { break }
                guard let targetCol = dataColumnIndex(atDisplayPosition: targetPosition) else { continue }
                let text = Self.pastedText(cellValue, columnType: tableRows.editingColumnType(at: targetCol))
                if !commitEnteredText(text, row: targetRow, columnIndex: targetCol) {
                    refusedCell = true
                }
            }
        }

        undoManager?.endUndoGrouping()
        if refusedCell {
            NSSound.beep()
        }

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

        let grid = Self.pastedLines(text).map { $0.components(separatedBy: "\t") }
        guard let firstRow = grid.first else { return nil }

        /// Whole rows are routed away by the result's own column count, not the presented one.
        /// `TSVRowParser` fills from data index 0 and knows nothing about which columns are on
        /// screen, so handing it a block as wide as the *visible* run writes the fields into hidden
        /// or wrong columns. A block that matches the visible width but not the result's stays on
        /// the cell path, where every field is placed by display position. Row paste skips empty
        /// lines, so they do not decide the shape.
        let isSingleValue = grid.count == 1 && firstRow.count == 1
        let dataColumnCount = tableRowsProvider().columns.count
        let rowLines = grid.filter { $0 != [""] }
        if !isSingleValue, dataColumnCount > 0, !rowLines.isEmpty,
           rowLines.allSatisfy({ $0.count == dataColumnCount }) {
            return nil
        }

        guard let anchorPosition = displayPosition(ofDataColumnIndex: anchorColumn) else { return nil }
        let maxRow = min(anchorRow + grid.count, cachedRowCount)
        let maxCol = min(anchorPosition + Self.blockWidth(grid), presentedColumnCount)
        guard anchorRow < maxRow, anchorPosition < maxCol else { return nil }

        return grid
    }

    /// The widest line, since an empty line holds one field and may come first.
    static func blockWidth(_ grid: [[String]]) -> Int {
        grid.map(\.count).max() ?? 0
    }

    /// The grid copies a NULL cell as the text `NULL`. A date, number or boolean cannot hold those
    /// four letters, so there they paste as NULL rather than the server's zero date or an error. A
    /// text column keeps them: the same text is what a stored `'NULL'` copies as.
    static func pastedText(_ field: String, columnType: ColumnType?) -> String? {
        guard field == "NULL", let columnType, !columnType.hasEmptyValue,
              columnType.enumValues?.contains(field) != true else { return field }
        return nil
    }

    /// An empty line inside the block is an empty value and keeps the rows below it in place.
    /// Dropping it moved every later value up a row. Empty lines at the end are the line breaks a
    /// spreadsheet ends its copy with, not rows.
    ///
    /// A `\r\n` copy is folded to `\n` first. Split as it is, every row kept a `\r` on its last field,
    /// and split on both characters it read as an empty line between every two rows.
    static func pastedLines(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        while lines.count > 1, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}
