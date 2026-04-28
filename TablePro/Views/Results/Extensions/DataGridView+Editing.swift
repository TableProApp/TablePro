//
//  DataGridView+Editing.swift
//  TablePro
//

import AppKit
import SwiftUI

extension TableViewCoordinator {
    enum InlineEditEligibility {
        case eligible
        case needsOverlayEditor(value: String)
        case blocked
    }

    func inlineEditEligibility(row: Int, columnIndex: Int) -> InlineEditEligibility {
        guard isEditable else { return .blocked }
        guard row >= 0, columnIndex >= 0, columnIndex < rowProvider.columns.count else { return .blocked }
        guard !changeManager.isRowDeleted(row) else { return .blocked }

        let immutable = databaseType.map { PluginManager.shared.immutableColumns(for: $0) } ?? []
        if immutable.contains(rowProvider.columns[columnIndex]) {
            return .blocked
        }

        let columnName = rowProvider.columns[columnIndex]
        if rowProvider.columnForeignKeys[columnName] != nil { return .blocked }

        if columnIndex < rowProvider.columnTypes.count {
            let ct = rowProvider.columnTypes[columnIndex]
            if ct.isBooleanType || ct.isDateType || ct.isJsonType
                || ct.isBlobType || ct.isEnumType || ct.isSetType {
                return .blocked
            }
        }

        if dropdownColumns?.contains(columnIndex) == true { return .blocked }
        if typePickerColumns?.contains(columnIndex) == true { return .blocked }

        if let value = rowProvider.value(atRow: row, column: columnIndex) {
            if value.containsLineBreak { return .needsOverlayEditor(value: value) }
            if value.looksLikeJson { return .blocked }
        }

        return .eligible
    }

    func canStartInlineEdit(row: Int, columnIndex: Int) -> Bool {
        if case .eligible = inlineEditEligibility(row: row, columnIndex: columnIndex) {
            return true
        }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        guard let tableColumn else { return false }
        guard tableColumn.identifier.rawValue != "__rowNumber__" else { return false }
        guard let columnIndex = DataGridView.dataColumnIndex(from: tableColumn.identifier) else { return false }

        switch inlineEditEligibility(row: row, columnIndex: columnIndex) {
        case .eligible:
            return true
        case .needsOverlayEditor(let value):
            let tableColumnIdx = tableView.column(withIdentifier: tableColumn.identifier)
            guard tableColumnIdx >= 0 else { return false }
            showOverlayEditor(tableView: tableView, row: row, column: tableColumnIdx, columnIndex: columnIndex, value: value)
            return false
        case .blocked:
            return false
        }
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
        commitCellEdit(row: row, columnIndex: columnIndex, newValue: newValue)
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

        let columnIndex = DataGridView.dataColumnIndex(for: column)

        if isEscapeCancelling {
            isEscapeCancelling = false
            let originalValue = rowProvider.value(atRow: row, column: columnIndex)
            textField.stringValue = originalValue ?? ""
            (control as? CellTextField)?.restoreTruncatedDisplay()
            return true
        }

        let rawInput = textField.stringValue
        let oldValue = rowProvider.value(atRow: row, column: columnIndex)
        let newValue: String? = rawInput.isEmpty && oldValue == nil ? nil : rawInput

        commitCellEdit(row: row, columnIndex: columnIndex, newValue: newValue)

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

            Task { @MainActor in
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

            Task { @MainActor in
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
            isEscapeCancelling = true
            tableView.window?.makeFirstResponder(tableView)
            return true
        }

        return false
    }
}
