//
//  DataGridCommands+Paste.swift
//  TablePro
//

import AppKit
import TableProPluginKit

// The clipboard read as cells: the fields the grid's own copy carries, or the text split into lines and fields.
// Only the grid's copy can hold a NULL.
struct DataGridCellPasteBlock: Equatable {
    // Splitting costs a pass over the whole string and validation asks on every Command-V, so past this the
    // clipboard is not a cell block and goes to row paste.
    static let maxLength = 1_000_000

    let lines: [[String?]]
    let isGridCopy: Bool
    var expressionFields: [Int: Set<Int>] = [:]

    // The widest line, since an empty line holds one field and may come first.
    var width: Int { lines.map(\.count).max() ?? 0 }

    var isSingleValue: Bool { lines.count == 1 && lines.first?.count == 1 }

    func isExpression(line: Int, field: Int) -> Bool {
        expressionFields[line]?.contains(field) == true
    }

    // Nil when the clipboard holds the grid's own row copy, which row paste reads.
    @MainActor
    static func fromClipboard() -> DataGridCellPasteBlock? {
        let clipboard = ClipboardService.shared
        guard !clipboard.hasGridRows, let text = clipboard.readText(), !text.isEmpty,
              (text as NSString).length <= maxLength else { return nil }
        if let copied = clipboard.readGridCells(), copied.text == text {
            return DataGridCellPasteBlock(lines: copied.fields, isGridCopy: true, expressionFields: copied.expressionFields ?? [:])
        }
        return DataGridCellPasteBlock(lines: pastedLines(text).map { $0.components(separatedBy: "\t") }, isGridCopy: false)
    }

    // A CRLF copy folds to LF; empty lines at the end are a spreadsheet's trailing breaks, not rows.
    static func pastedLines(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        while lines.count > 1, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    // Text from another app has no NULL of its own: a date, number or boolean cannot hold the letters NULL, so there
    // they paste as NULL; a text column keeps them.
    static func pastedText(_ field: String, columnType: ColumnType?) -> String? {
        guard field == "NULL", let columnType, !columnType.hasEmptyValue,
              columnType.enumValues?.contains(field) != true else { return field }
        return nil
    }
}

extension DataGridCommands {
    // MARK: - Planning

    // One value over a multi-cell selection fills every cell, as a spreadsheet pastes it.
    func pasteFillTargets(_ scope: DataGridCommandScope, block: DataGridCellPasteBlock) -> [DataGridCommandCell]? {
        guard block.isSingleValue else { return nil }
        let targets = cells(scope)
        return targets.count > 1 ? targets : nil
    }

    // Where a block lands, from the focus cell rightwards and down in display order. A block as wide as the result,
    // line for line, is whole rows and goes to row paste.
    func pasteAnchor(_ scope: DataGridCommandScope, block: DataGridCellPasteBlock) -> GridCoord? {
        guard !scope.isRowHeader, let anchor = scope.focus ?? scope.selection.activeCell, !block.lines.isEmpty else {
            return nil
        }
        let dataColumnCount = model.rows.columns.count
        let rowLines = block.lines.filter { $0 != [""] }
        if !block.isSingleValue, dataColumnCount > 0, !rowLines.isEmpty,
           rowLines.allSatisfy({ $0.count == dataColumnCount }) {
            return nil
        }
        guard anchor.row >= 0, anchor.row < model.rowCount,
              anchor.displayColumn >= 0, anchor.displayColumn < model.columns.count else { return nil }
        return anchor
    }

    func canPaste(_ scope: DataGridCommandScope) -> Bool {
        guard configuration.isEditable else { return false }
        if offers(.pasteRows), model.actions?.gridCanPasteRows() == true { return true }
        guard let block = DataGridCellPasteBlock.fromClipboard() else { return false }
        return pasteFillTargets(scope, block: block) != nil || pasteAnchor(scope, block: block) != nil
    }

    // Menu and keyboard take this one path: fill the selection, else a block at the focus cell, else row paste.
    func paste(_ scope: DataGridCommandScope) {
        guard configuration.isEditable else { return }
        if let block = DataGridCellPasteBlock.fromClipboard() {
            if let targets = pasteFillTargets(scope, block: block) {
                pasteFill(block, into: targets, scope: scope)
                return
            }
            if let anchor = pasteAnchor(scope, block: block) {
                pasteBlock(block, at: anchor, scope: scope)
                return
            }
        }
        guard offers(.pasteRows), model.actions?.gridCanPasteRows() == true else { return }
        model.actions?.gridPasteRows()
    }

    // MARK: - Writing

    private func pasteFill(_ block: DataGridCellPasteBlock, into targets: [DataGridCommandCell], scope: DataGridCommandScope) {
        let columns = IndexSet(targets.map(\.column.dataIndex))
        // The retry keeps these targets and this block: a filter or a new clipboard while values load must not move them.
        guard loader.ensureLoaded(targets.map(\.rowID), columns: columns, in: model, retry: {
            pasteFill(block, into: targets, scope: scope)
        }) else { return }
        let field = block.lines.first?.first ?? nil
        let isExpression = block.isExpression(line: 0, field: 0)
        applyEntry(to: targets, actionName: String(localized: "Paste Cells")) { column in
            pastedEntry(field, of: block, isExpression: isExpression, column: column)
        }
    }

    private func pasteBlock(_ block: DataGridCellPasteBlock, at anchor: GridCoord, scope: DataGridCommandScope) {
        let maxRow = min(anchor.row + block.lines.count, model.rowCount)
        let maxColumn = min(anchor.displayColumn + block.width, model.columns.count)
        guard anchor.row < maxRow, anchor.displayColumn < maxColumn else { return }

        var edits: [DataGridCellEdit] = []
        var refused = false
        for (lineIndex, fields) in block.lines.enumerated() {
            let targetRow = anchor.row + lineIndex
            guard targetRow < maxRow else { break }
            guard let rowID = model.rowID(at: targetRow), !isRowDeleted(rowID) else { continue }
            for (fieldIndex, field) in fields.enumerated() {
                let position = anchor.displayColumn + fieldIndex
                guard position < maxColumn else { break }
                guard let column = model.columns.column(at: position) else { continue }
                guard let entry = pastedEntry(
                    field,
                    of: block,
                    isExpression: block.isExpression(line: lineIndex, field: fieldIndex),
                    column: column
                ) else {
                    refused = true
                    continue
                }
                edits.append(DataGridCellEdit(
                    rowID: rowID,
                    columnID: column.id,
                    value: .value(entry.value, isExpression: entry.isExpression)
                ))
            }
        }
        commitPasted(edits, refused: refused)
    }

    // Targets are fixed by identity before any value loads, so the retry writes the cells the paste first named.
    private func commitPasted(_ edits: [DataGridCellEdit], refused: Bool) {
        var rowIDs: [RowID] = []
        var seen = Set<RowID>()
        for edit in edits where seen.insert(edit.rowID).inserted {
            rowIDs.append(edit.rowID)
        }
        let columns = IndexSet(edits.compactMap { model.columns.column(id: $0.columnID)?.dataIndex })
        guard loader.ensureLoaded(rowIDs, columns: columns, in: model, retry: {
            commitPasted(edits, refused: refused)
        }) else { return }
        if !edits.isEmpty {
            model.commit(edits, actionName: String(localized: "Paste Cells"))
        }
        if refused {
            NSSound.beep()
        }
    }

    // The grid's copy says which fields were SQL; any other field is text however it reads. Text from another app is
    // read the way a typed cell is.
    func pastedEntry(
        _ field: String?,
        of block: DataGridCellPasteBlock,
        isExpression: Bool,
        column: DataGridColumn
    ) -> StagedCellEntry? {
        let rows = model.rows
        guard block.isGridCopy else {
            let text = field.flatMap {
                DataGridCellPasteBlock.pastedText($0, columnType: rows.editingColumnType(at: column.dataIndex))
            }
            return enteredCell(text, column: column)
        }
        if isExpression, let field {
            return (value: .text(field), isExpression: true)
        }
        return rows.enteredValue(field, forColumn: column.dataIndex).map { (value: $0, isExpression: false) }
    }
}
