//
//  DataGridView+Editing.swift
//  TablePro
//

import AppKit
import SwiftUI

extension TableViewCoordinator {
    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        guard isEditable,
              let tableColumn = tableColumn else { return false }

        let columnId = tableColumn.identifier.rawValue
        guard columnId != "__rowNumber__",
              !changeManager.isRowDeleted(row) else { return false }

        let immutable = databaseType.map { PluginManager.shared.immutableColumns(for: $0) } ?? []
        if !immutable.isEmpty,
           columnId.hasPrefix("col_"),
           let columnIndex = Int(columnId.dropFirst(4)),
           columnIndex < rowProvider.columns.count,
           immutable.contains(rowProvider.columns[columnIndex]) {
            return false
        }

        // Popover-editor columns (date/FK/JSON) are only editable via
        // double-click (handleDoubleClick). Block inline editing for them.
        if columnId.hasPrefix("col_"),
           let columnIndex = Int(columnId.dropFirst(4)) {
            if columnIndex < rowProvider.columns.count {
                let columnName = rowProvider.columns[columnIndex]
                if rowProvider.columnForeignKeys[columnName] != nil { return false }
            }
            if columnIndex < rowProvider.columnTypes.count {
                let ct = rowProvider.columnTypes[columnIndex]
                if ct.isDateType || ct.isJsonType || ct.isEnumType || ct.isSetType || ct.isBlobType || ct.isBooleanType { return false }
            }
            if let dropdownCols = dropdownColumns, dropdownCols.contains(columnIndex) {
                return false
            }
            if let typePickerCols = typePickerColumns, typePickerCols.contains(columnIndex) {
                return false
            }

            // Text columns containing JSON use JSON editor popover
            if let value = rowProvider.value(atRow: row, column: columnIndex),
               value.looksLikeJson {
                return false
            }

            // Multiline values use overlay editor — block inline field editor
            if let value = rowProvider.value(atRow: row, column: columnIndex),
               value.containsLineBreak {
                let tableColumnIdx = tableView.column(withIdentifier: tableColumn.identifier)
                guard tableColumnIdx >= 0 else { return false }
                showOverlayEditor(tableView: tableView, row: row, column: tableColumnIdx, columnIndex: columnIndex, value: value)
                return false
            }
        }

        return true
    }

    // MARK: - Overlay Editor (Multiline)

    func showOverlayEditor(tableView: NSTableView, row: Int, column: Int, columnIndex: Int, value: String) {
        if overlayEditor == nil {
            overlayEditor = CellOverlayEditor()
        }
        guard let editor = overlayEditor else { return }

        editor.onCommit = { [weak self] row, columnIndex, newValue in
            self?.commitOverlayEdit(row: row, columnIndex: columnIndex, newValue: newValue)
        }
        editor.onTabNavigation = { [weak self] row, column, forward in
            self?.handleOverlayTabNavigation(row: row, column: column, forward: forward)
        }
        editor.show(in: tableView, row: row, column: column, columnIndex: columnIndex, value: value)
    }

    func commitOverlayEdit(row: Int, columnIndex: Int, newValue: String) {
        let oldValue = rowProvider.value(atRow: row, column: columnIndex)
        guard oldValue != newValue else { return }

        let columnName = rowProvider.columns[columnIndex]
        changeManager.recordCellChange(
            rowIndex: row,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: rowProvider.rowValues(at: row) ?? []
        )

        rowProvider.updateValue(newValue, at: row, columnIndex: columnIndex)
        onCellEdit?(row, columnIndex, newValue)

        let tableColumnIndex = columnIndex + 1
        tableView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: tableColumnIndex))
    }

    func handleOverlayTabNavigation(row: Int, column: Int, forward: Bool) {
        guard let tableView = tableView else { return }

        var nextColumn = forward ? column + 1 : column - 1
        var nextRow = row

        if forward {
            if nextColumn >= tableView.numberOfColumns {
                nextColumn = 1
                nextRow += 1
            }
            if nextRow >= tableView.numberOfRows {
                nextRow = tableView.numberOfRows - 1
                nextColumn = tableView.numberOfColumns - 1
            }
        } else {
            if nextColumn < 1 {
                nextColumn = tableView.numberOfColumns - 1
                nextRow -= 1
            }
            if nextRow < 0 {
                nextRow = 0
                nextColumn = 1
            }
        }

        tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)

        // Check if next cell is also multiline → open overlay there
        let nextColumnIndex = nextColumn - 1
        if nextColumnIndex >= 0, nextColumnIndex < rowProvider.columns.count,
           let value = rowProvider.value(atRow: nextRow, column: nextColumnIndex),
           value.containsLineBreak {
            showOverlayEditor(tableView: tableView, row: nextRow, column: nextColumn, columnIndex: nextColumnIndex, value: value)
        } else {
            tableView.editColumn(nextColumn, row: nextRow, with: nil, select: true)
        }
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard let textField = control as? NSTextField, let tableView = tableView else { return true }

        let row = tableView.row(for: textField)
        let column = tableView.column(for: textField)

        guard row >= 0, column > 0 else { return true }

        let columnIndex = column - 1
        let newValue: String? = textField.stringValue

        let oldValue = rowProvider.value(atRow: row, column: columnIndex)

        guard oldValue != newValue else { return true }

        let columnName = rowProvider.columns[columnIndex]
        changeManager.recordCellChange(
            rowIndex: row,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: rowProvider.rowValues(at: row) ?? []
        )

        rowProvider.updateValue(newValue, at: row, columnIndex: columnIndex)
        onCellEdit?(row, columnIndex, newValue)

        DispatchQueue.main.async {
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
        }

        (control as? CellTextField)?.restoreTruncatedDisplay()

        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let tableView = tableView else { return false }

        let currentRow = tableView.row(for: control)
        let currentColumn = tableView.column(for: control)

        guard currentRow >= 0, currentColumn >= 0 else { return false }

        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            tableView.window?.makeFirstResponder(tableView)

            var nextColumn = currentColumn + 1
            var nextRow = currentRow

            if nextColumn >= tableView.numberOfColumns {
                nextColumn = 1
                nextRow += 1
            }
            if nextRow >= tableView.numberOfRows {
                nextRow = tableView.numberOfRows - 1
                nextColumn = tableView.numberOfColumns - 1
            }

            DispatchQueue.main.async {
                tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
                tableView.editColumn(nextColumn, row: nextRow, with: nil, select: true)
            }
            return true
        }

        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            tableView.window?.makeFirstResponder(tableView)

            var prevColumn = currentColumn - 1
            var prevRow = currentRow

            if prevColumn < 1 {
                prevColumn = tableView.numberOfColumns - 1
                prevRow -= 1
            }
            if prevRow < 0 {
                prevRow = 0
                prevColumn = 1
            }

            DispatchQueue.main.async {
                tableView.selectRowIndexes(IndexSet(integer: prevRow), byExtendingSelection: false)
                tableView.editColumn(prevColumn, row: prevRow, with: nil, select: true)
            }
            return true
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            tableView.window?.makeFirstResponder(tableView)
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            tableView.window?.makeFirstResponder(tableView)
            return true
        }

        return false
    }
}
