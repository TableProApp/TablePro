//
//  DataGridView+Click.swift
//  TablePro
//

import AppKit
import SwiftUI

extension TableViewCoordinator {
    // MARK: - Click Handlers

    @objc func handleDoubleClick(_ sender: NSTableView) {
        let row = sender.clickedRow
        let column = sender.clickedColumn
        guard row >= 0, column > 0 else { return }
        guard let columnIndex = DataGridView.dataColumnIndex(for: column, in: sender, schema: identitySchema) else { return }
        handleCellInteraction(row: row, tableColumn: column, columnIndex: columnIndex, tableView: sender)
    }

    func handleCellInteraction(row: Int, tableColumn: Int, columnIndex: Int, tableView: NSTableView) {
        guard let context = makeCellContext(row: row, columnIndex: columnIndex) else { return }
        guard tableView.view(atColumn: tableColumn, row: row, makeIfNecessary: false) != nil else { return }

        switch CellInteractionResolver().resolve(context) {
        case .blocked:
            return
        case .viewInline(let value):
            showOverlayViewer(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex, value: value)
        case .viewJson:
            showJSONViewerPopover(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex)
        case .viewBlob:
            showBlobViewerPopover(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex)
        case .editInline:
            beginCellEdit(row: row, tableColumnIndex: tableColumn)
        case .editOverlay(let value):
            showOverlayEditor(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex, value: value)
        case .editJson:
            showJSONEditorPopover(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex)
        case .editBlob:
            showBlobEditorPopover(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex)
        case .editForeignKey(let fkInfo):
            showForeignKeyPopover(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex, fkInfo: fkInfo)
        case .editDropdown:
            showDropdownMenu(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex)
        case .editEnum:
            showEnumPopover(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex)
        case .editSet:
            showSetPopover(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex)
        case .editTypePicker:
            showTypePickerPopover(tableView: tableView, row: row, column: tableColumn, columnIndex: columnIndex)
        }
    }

    private func makeCellContext(row: Int, columnIndex: Int) -> CellContext? {
        let tableRows = tableRowsProvider()
        guard row >= 0, columnIndex >= 0, columnIndex < tableRows.columns.count else { return nil }

        let columnName = tableRows.columns[columnIndex]
        let columnType = columnIndex < tableRows.columnTypes.count ? tableRows.columnTypes[columnIndex] : nil
        let immutable = databaseType.map { PluginManager.shared.immutableColumns(for: $0) } ?? []
        let hasEnumValues = (tableRows.columnEnumValues[columnName]?.isEmpty == false)

        return CellContext(
            row: row,
            columnIndex: columnIndex,
            columnName: columnName,
            columnType: columnType,
            value: cellValue(at: row, column: columnIndex),
            isTableEditable: isEditable,
            isRowDeleted: changeManager.isRowDeleted(row),
            isImmutableColumn: immutable.contains(columnName),
            foreignKeyInfo: tableRows.columnForeignKeys[columnName],
            isDropdownColumn: dropdownColumns?.contains(columnIndex) == true,
            isTypePickerColumn: typePickerColumns?.contains(columnIndex) == true,
            hasEnumValues: hasEnumValues
        )
    }

    // MARK: - Chevron Click

    func handleChevronAction(row: Int, columnIndex: Int) {
        guard let tableView else { return }
        guard let column = DataGridView.tableColumnIndex(
            for: columnIndex,
            in: tableView,
            schema: identitySchema
        ) else { return }
        handleCellInteraction(row: row, tableColumn: column, columnIndex: columnIndex, tableView: tableView)
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
