//
//  DataGridView+Click.swift
//  TablePro
//

import AppKit
import SwiftUI

extension TableViewCoordinator {
    // MARK: - Click Handlers

    @objc func handleDoubleClick(_ sender: NSTableView) {
        guard isEditable else { return }

        let row = sender.clickedRow
        let column = sender.clickedColumn
        guard row >= 0, column > 0 else { return }

        guard let columnIndex = DataGridView.dataColumnIndex(for: column, in: sender, schema: identitySchema) else { return }
        guard !changeManager.isRowDeleted(row) else { return }

        let tableRows = tableRowsProvider()
        let immutable = databaseType.map { PluginManager.shared.immutableColumns(for: $0) } ?? []
        if !immutable.isEmpty,
           columnIndex < tableRows.columns.count,
           immutable.contains(tableRows.columns[columnIndex]) {
            return
        }

        if columnIndex < tableRows.columns.count {
            let columnName = tableRows.columns[columnIndex]
            if let fkInfo = tableRows.columnForeignKeys[columnName] {
                showForeignKeyPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex, fkInfo: fkInfo)
                return
            }
        }

        let value = cellValue(at: row, column: columnIndex)
        if let value, value.containsLineBreak {
            showOverlayEditor(tableView: sender, row: row, column: column, columnIndex: columnIndex, value: value)
            return
        }

        if columnIndex < tableRows.columnTypes.count {
            let ct = tableRows.columnTypes[columnIndex]
            if ct.isBooleanType || ct.isDateType || ct.isBlobType || ct.isEnumType || ct.isSetType {
                return
            }
        }
        if let value, value.looksLikeJson {
            showJSONEditorPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex)
            return
        }

        beginCellEdit(row: row, tableColumnIndex: column)
    }

    // MARK: - Chevron Click

    func handleChevronAction(row: Int, columnIndex: Int) {
        guard isEditable else { return }
        guard row >= 0, columnIndex >= 0 else { return }
        guard !changeManager.isRowDeleted(row) else { return }
        guard let tableView else { return }
        guard let column = DataGridView.tableColumnIndex(
            for: columnIndex,
            in: tableView,
            schema: identitySchema
        ) else { return }

        if let dropdownCols = dropdownColumns, dropdownCols.contains(columnIndex) {
            showDropdownMenu(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
            return
        }
        if let typePickerCols = typePickerColumns, typePickerCols.contains(columnIndex) {
            showTypePickerPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
            return
        }

        let tableRows = tableRowsProvider()
        guard columnIndex < tableRows.columnTypes.count,
              columnIndex < tableRows.columns.count else { return }

        let ct = tableRows.columnTypes[columnIndex]
        let columnName = tableRows.columns[columnIndex]

        if ct.isBooleanType {
            showDropdownMenu(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
        } else if ct.isEnumType, let values = tableRows.columnEnumValues[columnName], !values.isEmpty {
            showEnumPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
        } else if ct.isSetType, let values = tableRows.columnEnumValues[columnName], !values.isEmpty {
            showSetPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
        } else if ct.isDateType {
            showDatePickerPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
        } else if ct.isJsonType {
            showJSONEditorPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
        } else if ct.isBlobType {
            showBlobEditorPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
        }
    }

    // MARK: - FK Navigation

    func handleFKArrowAction(row: Int, columnIndex: Int) {
        let tableRows = tableRowsProvider()
        guard row >= 0 && row < cachedRowCount,
              columnIndex >= 0 && columnIndex < tableRows.columns.count else { return }

        let columnName = tableRows.columns[columnIndex]
        guard let fkInfo = tableRows.columnForeignKeys[columnName] else { return }

        let value = cellValue(at: row, column: columnIndex)
        guard let value = value, !value.isEmpty else { return }

        delegate?.dataGridNavigateFK(value: value, fkInfo: fkInfo)
    }

    // MARK: - Type Picker Popover

    func showTypePickerPopover(
        tableView: NSTableView,
        row: Int,
        column: Int,
        columnIndex: Int
    ) {
        guard tableView.view(atColumn: column, row: row, makeIfNecessary: false) != nil else { return }

        let currentValue = cellValue(at: row, column: columnIndex) ?? ""
        let dbType = databaseType ?? .mysql

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView
        ) { [weak self] dismiss in
            TypePickerContentView(
                databaseType: dbType,
                currentValue: currentValue,
                onCommit: { newValue in
                    guard let self else { return }
                    self.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss
            )
        }
    }
}
