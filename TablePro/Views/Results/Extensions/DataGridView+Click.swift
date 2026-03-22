//
//  DataGridView+Click.swift
//  TablePro
//

import AppKit
import SwiftUI

extension TableViewCoordinator {
    // MARK: - Click Handlers

    @objc func handleClick(_ sender: NSTableView) {
        guard isEditable else { return }

        let row = sender.clickedRow
        let column = sender.clickedColumn
        guard row >= 0, column > 0 else { return }

        let columnIndex = column - 1
        guard !changeManager.isRowDeleted(row) else { return }

        // Dropdown columns open on single click
        if let dropdownCols = dropdownColumns, dropdownCols.contains(columnIndex) {
            showDropdownMenu(tableView: sender, row: row, column: column, columnIndex: columnIndex)
            return
        }

        // ENUM/SET columns open on single click
        if columnIndex < rowProvider.columnTypes.count,
           columnIndex < rowProvider.columns.count {
            let ct = rowProvider.columnTypes[columnIndex]
            let columnName = rowProvider.columns[columnIndex]
            if ct.isEnumType, let values = rowProvider.columnEnumValues[columnName], !values.isEmpty {
                showEnumPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex)
                return
            }
            if ct.isSetType, let values = rowProvider.columnEnumValues[columnName], !values.isEmpty {
                showSetPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex)
                return
            }
        }
    }

    @objc func handleDoubleClick(_ sender: NSTableView) {
        guard isEditable else { return }

        let row = sender.clickedRow
        let column = sender.clickedColumn
        guard row >= 0, column > 0 else { return }

        let columnIndex = column - 1
        guard !changeManager.isRowDeleted(row) else { return }

        let immutable = databaseType.map { PluginManager.shared.immutableColumns(for: $0) } ?? []
        if !immutable.isEmpty,
           columnIndex < rowProvider.columns.count,
           immutable.contains(rowProvider.columns[columnIndex]) {
            return
        }

        // Dropdown columns already handled by single click
        if let dropdownCols = dropdownColumns, dropdownCols.contains(columnIndex) {
            return
        }

        // Type picker columns use database-specific type popover
        if let typePickerCols = typePickerColumns, typePickerCols.contains(columnIndex) {
            showTypePickerPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex)
            return
        }

        // ENUM/SET columns already handled by single click
        if columnIndex < rowProvider.columnTypes.count,
           columnIndex < rowProvider.columns.count {
            let ct = rowProvider.columnTypes[columnIndex]
            if ct.isEnumType || ct.isSetType {
                let columnName = rowProvider.columns[columnIndex]
                if let values = rowProvider.columnEnumValues[columnName], !values.isEmpty {
                    return
                }
            }
        }

        // FK columns use searchable dropdown popover
        if columnIndex < rowProvider.columns.count {
            let columnName = rowProvider.columns[columnIndex]
            if let fkInfo = rowProvider.columnForeignKeys[columnName] {
                showForeignKeyPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex, fkInfo: fkInfo)
                return
            }
        }

        // Date columns use date picker popover
        if columnIndex < rowProvider.columnTypes.count,
           rowProvider.columnTypes[columnIndex].isDateType {
            showDatePickerPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex)
            return
        }

        // JSON columns use JSON editor popover
        if columnIndex < rowProvider.columnTypes.count,
           rowProvider.columnTypes[columnIndex].isJsonType {
            showJSONEditorPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex)
            return
        }

        // BLOB columns use hex editor popover
        if columnIndex < rowProvider.columnTypes.count,
           rowProvider.columnTypes[columnIndex].isBlobType {
            showBlobEditorPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex)
            return
        }

        // Multiline values use the overlay editor instead of inline field editor
        if let value = rowProvider.value(atRow: row, column: columnIndex),
           value.containsLineBreak {
            showOverlayEditor(tableView: sender, row: row, column: column, columnIndex: columnIndex, value: value)
            return
        }

        // Regular columns — start inline editing
        sender.editColumn(column, row: row, with: nil, select: true)
    }

    // MARK: - FK Navigation

    @objc func handleFKArrowClick(_ sender: NSButton) {
        guard let button = sender as? FKArrowButton else { return }
        let row = button.fkRow
        let columnIndex = button.fkColumnIndex

        guard row >= 0 && row < cachedRowCount,
              columnIndex >= 0 && columnIndex < rowProvider.columns.count else { return }

        let columnName = rowProvider.columns[columnIndex]
        guard let fkInfo = rowProvider.columnForeignKeys[columnName] else { return }

        let value = rowProvider.value(atRow: row, column: columnIndex)
        guard let value = value, !value.isEmpty else { return }

        onNavigateFK?(value, fkInfo)
    }
}
