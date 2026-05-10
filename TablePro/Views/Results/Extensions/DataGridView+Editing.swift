//
//  DataGridView+Editing.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

extension TableViewCoordinator {
    enum EditEligibility {
        case editable(value: String)
        case blocked
    }

    func editEligibility(row: Int, columnIndex: Int) -> EditEligibility {
        guard isEditable else { return .blocked }
        let tableRows = tableRowsProvider()
        guard row >= 0, columnIndex >= 0, columnIndex < tableRows.columns.count else { return .blocked }
        guard !changeManager.isRowDeleted(row) else { return .blocked }

        let immutable = databaseType.map { PluginManager.shared.immutableColumns(for: $0) } ?? []
        if immutable.contains(tableRows.columns[columnIndex]) { return .blocked }

        let columnName = tableRows.columns[columnIndex]
        if tableRows.columnForeignKeys[columnName] != nil { return .blocked }

        if columnIndex < tableRows.columnTypes.count {
            let ct = tableRows.columnTypes[columnIndex]
            if ct.isBooleanType || ct.isDateType || ct.isJsonType
                || ct.isBlobType || ct.isEnumType || ct.isSetType {
                return .blocked
            }
        }

        // Note: dropdown / type-picker columns are deliberately *not* blocked
        // here. The chevron button opens the popup, while the cell body still
        // accepts inline text edit so the user can type a value the picker
        // doesn't list (custom column type, numeric default, etc). Compare
        // NSComboBox: the field is text-editable AND the chevron lists
        // predefined options.

        let value: String
        if let displayRow = displayRow(at: row),
           columnIndex < displayRow.values.count,
           let raw = displayRow.values[columnIndex].asText {
            value = raw
        } else {
            value = ""
        }
        return .editable(value: value)
    }

    func canStartInlineEdit(row: Int, columnIndex: Int) -> Bool {
        if case .editable = editEligibility(row: row, columnIndex: columnIndex) {
            return true
        }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        false
    }

    func beginCellEdit(row: Int, tableColumnIndex: Int) {
        guard let tableView else { return }
        guard tableColumnIndex >= 0, tableColumnIndex < tableView.numberOfColumns else { return }
        let column = tableView.tableColumns[tableColumnIndex]
        guard column.identifier != ColumnIdentitySchema.rowNumberIdentifier else { return }
        guard let columnIndex = dataColumnIndex(from: column.identifier) else { return }
        guard case .editable(let value) = editEligibility(row: row, columnIndex: columnIndex) else { return }
        showOverlayEditor(
            tableView: tableView,
            row: row,
            column: tableColumnIndex,
            columnIndex: columnIndex,
            value: value
        )
    }

    // MARK: - Overlay Editor

    func showOverlayEditor(tableView: NSTableView, row: Int, column: Int, columnIndex: Int, value: String) {
        if overlayEditor == nil {
            overlayEditor = CellOverlayEditor()
        }
        guard let editor = overlayEditor else { return }

        editor.onCommit = { [weak self] row, columnIndex, newValue in
            self?.commitCellEdit(row: row, columnIndex: columnIndex, newValue: newValue)
        }
        editor.onTabNavigation = { [weak self] row, column, forward in
            self?.handleOverlayTabNavigation(row: row, column: column, forward: forward)
        }
        editor.show(in: tableView, row: row, column: column, columnIndex: columnIndex, value: value)
    }

    func handleOverlayTabNavigation(row: Int, column: Int, forward: Bool) {
        guard let tableView = tableView else { return }

        var nextColumn = forward ? column + 1 : column - 1
        var nextRow = row

        if forward {
            if nextColumn >= tableView.numberOfColumns {
                nextColumn = DataGridView.firstDataTableColumnIndex
                nextRow += 1
            }
            if nextRow >= tableView.numberOfRows {
                nextRow = tableView.numberOfRows - 1
                nextColumn = tableView.numberOfColumns - 1
            }
        } else {
            if !DataGridView.isDataTableColumn(nextColumn) {
                nextColumn = tableView.numberOfColumns - 1
                nextRow -= 1
            }
            if nextRow < 0 {
                nextRow = 0
                nextColumn = DataGridView.firstDataTableColumnIndex
            }
        }

        tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)

        guard let nextColumnIndex = DataGridView.dataColumnIndex(
                for: nextColumn,
                in: tableView,
                schema: identitySchema
              ),
              nextColumnIndex >= 0,
              case .editable(let value) = editEligibility(row: nextRow, columnIndex: nextColumnIndex)
        else { return }

        showOverlayEditor(
            tableView: tableView,
            row: nextRow,
            column: nextColumn,
            columnIndex: nextColumnIndex,
            value: value
        )
    }
}
