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

        // Structure view dropdown columns (no chevron button — use full-cell click)
        if let dropdownCols = dropdownColumns, dropdownCols.contains(columnIndex) {
            showDropdownMenu(tableView: sender, row: row, column: column, columnIndex: columnIndex)
            return
        }

        // All other special editor columns are handled by their chevron button action.
        // Single click on cell text area does nothing.
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

        // FK columns use searchable dropdown popover on double click
        if columnIndex < rowProvider.columns.count {
            let columnName = rowProvider.columns[columnIndex]
            if let fkInfo = rowProvider.columnForeignKeys[columnName] {
                showForeignKeyPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex, fkInfo: fkInfo)
                return
            }
        }

        // Multiline values use the overlay editor instead of inline field editor
        if let value = rowProvider.value(atRow: row, column: columnIndex),
           value.containsLineBreak {
            showOverlayEditor(tableView: sender, row: row, column: column, columnIndex: columnIndex, value: value)
            return
        }

        // JSON-like text values in non-JSON/non-chevron columns
        if columnIndex < rowProvider.columnTypes.count {
            let ct = rowProvider.columnTypes[columnIndex]
            if ct.isBooleanType || ct.isDateType || ct.isBlobType || ct.isEnumType || ct.isSetType {
                return
            }
        }
        if let cellValue = rowProvider.value(atRow: row, column: columnIndex),
           cellValue.looksLikeJson {
            showJSONEditorPopover(tableView: sender, row: row, column: column, columnIndex: columnIndex)
            return
        }

        // Regular columns — start inline editing
        sender.editColumn(column, row: row, with: nil, select: true)
    }

    // MARK: - Chevron Click

    @objc func handleChevronClick(_ sender: NSButton) {
        guard let button = sender as? CellChevronButton,
              isEditable else { return }

        let row = button.cellRow
        let columnIndex = button.cellColumnIndex
        guard row >= 0, columnIndex >= 0 else { return }
        guard !changeManager.isRowDeleted(row) else { return }

        // Walk up the view hierarchy to find the NSTableView
        var current: NSView? = button.superview
        var tableView: NSTableView?
        while let view = current {
            if let tv = view as? NSTableView {
                tableView = tv
                break
            }
            current = view.superview
        }
        guard let tableView else { return }
        let column = columnIndex + 1

        // Structure view: dropdown and type picker columns take priority
        if let dropdownCols = dropdownColumns, dropdownCols.contains(columnIndex) {
            showDropdownMenu(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
            return
        }
        if let typePickerCols = typePickerColumns, typePickerCols.contains(columnIndex) {
            showTypePickerPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
            return
        }

        guard columnIndex < rowProvider.columnTypes.count,
              columnIndex < rowProvider.columns.count else { return }

        let ct = rowProvider.columnTypes[columnIndex]
        let columnName = rowProvider.columns[columnIndex]

        if ct.isBooleanType {
            showDropdownMenu(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
        } else if ct.isEnumType, let values = rowProvider.columnEnumValues[columnName], !values.isEmpty {
            showEnumPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
        } else if ct.isSetType, let values = rowProvider.columnEnumValues[columnName], !values.isEmpty {
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
