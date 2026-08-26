//
//  DataGridView+Click.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

extension TableViewCoordinator {
    // MARK: - Cell Interaction

    /// Whether a cell is on screen for something to anchor to.
    ///
    /// A data cell is drawn rather than mounted, so the row being on screen is what answers this;
    /// `view(atColumn:row:makeIfNecessary:)` is always nil now and every guard that still asked it
    /// closed the editor or popover it was guarding (#2381).
    func presentsCell(row: Int, tableColumnIndex: Int) -> Bool {
        guard let tableView, row >= 0, row < tableView.numberOfRows else { return false }
        guard presentsColumn(atTableColumnIndex: tableColumnIndex) else { return false }
        return tableView.rowView(atRow: row, makeIfNecessary: false) != nil
    }

    func handleCellInteraction(row: Int, tableColumn: Int, columnIndex: Int, tableView: NSTableView) {
        guard let context = makeCellContext(row: row, columnIndex: columnIndex) else { return }
        guard presentsCell(row: row, tableColumnIndex: tableColumn) else { return }

        switch CellInteractionResolver().resolve(context) {
        case .blocked:
            return
        case .viewInline(let value):
            showOverlayViewer(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex, value: value)
        case .viewJson:
            showJSONViewerPopover(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex)
        case .viewBlob:
            showBlobViewerPopover(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex)
        case .viewPhpSerialized:
            showPhpViewerPopover(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex)
        case .editInline:
            beginCellEdit(row: row, tableColumnIndex: tableColumn)
        case .editOverlay(let value):
            showOverlayEditor(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex, value: value)
        case .editJson:
            showJSONEditorPopover(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex)
        case .editBlob:
            showBlobEditorPopover(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex)
        }
    }

    private func makeCellContext(row: Int, columnIndex: Int) -> CellContext? {
        let tableRows = tableRowsProvider()
        guard row >= 0, columnIndex >= 0, columnIndex < tableRows.columns.count else { return nil }

        let columnName = tableRows.columns[columnIndex]
        let columnType = columnIndex < tableRows.columnTypes.count ? tableRows.columnTypes[columnIndex] : nil
        let immutable = databaseType.map { PluginManager.shared.immutableColumns(for: $0) } ?? []
        let override = columnIndex < columnDisplayFormats.count
            ? columnDisplayFormats[columnIndex]
            : nil

        return CellContext(
            columnType: columnType,
            value: cellValue(at: row, column: columnIndex),
            isTableEditable: isEditable,
            isRowDeleted: changeManager.isRowDeleted(row),
            isImmutableColumn: immutable.contains(columnName),
            isBinaryValue: cellTypedValue(at: row, column: columnIndex).asBytes != nil,
            displayFormatOverride: override
        )
    }

    // MARK: - Chevron Click

    func handleChevronAction(row: Int, columnIndex: Int) {
        guard isEditable else { return }
        guard row >= 0, columnIndex >= 0 else { return }
        guard !changeManager.isRowDeleted(row) else { return }
        guard let tableView else { return }
        guard let column = tableColumnIndex(for: columnIndex) else { return }

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

        let columnType = tableRows.columnTypes[columnIndex]
        let columnName = tableRows.columns[columnIndex]

        if columnType.isBooleanType {
            showDropdownMenu(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
        } else if columnType.supportsElementEditing {
            showArrayEditorPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
        } else if let values = tableRows.columnEnumValues[columnName], !values.isEmpty {
            if columnType.isSetType {
                showSetPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
            } else {
                showEnumPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
            }
        } else if columnType.isJsonType {
            showJSONEditorPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
        } else if columnType.isBlobType {
            showBlobEditorPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
        } else if columnType.isDateType {
            if opensDatePicker(row: row, columnIndex: columnIndex) {
                showDateTimePickerPopover(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
            } else {
                beginEditing(displayRow: row, column: columnIndex)
            }
        } else if columnType.isEnumOrSetType {
            beginEditing(displayRow: row, column: columnIndex)
        }
    }

    // MARK: - FK Navigation

    func handleFKArrowAction(row: Int, columnIndex: Int, openInNewTab: Bool) {
        let tableRows = tableRowsProvider()
        guard row >= 0 && row < cachedRowCount,
              columnIndex >= 0 && columnIndex < tableRows.columns.count else { return }

        let columnName = tableRows.columns[columnIndex]
        guard let fkInfo = tableRows.columnForeignKeys[columnName] else { return }

        let value = cellValue(at: row, column: columnIndex)
        guard let value = value, !value.isEmpty else { return }

        delegate?.dataGridNavigateFK(value: value, fkInfo: fkInfo, openInNewTab: openInNewTab)
    }

    // MARK: - Type Picker Popover

    func showTypePickerPopover(
        tableView: NSTableView,
        row: Int,
        column: Int,
        columnIndex: Int
    ) {
        guard presentsCell(row: row, tableColumnIndex: column) else { return }

        let currentValue = cellValue(at: row, column: columnIndex) ?? ""
        let dbType = databaseType ?? .mysql

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        dismissActiveCellEditorPopover()
        activeCellEditorPopover = PopoverPresenter.show(
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
