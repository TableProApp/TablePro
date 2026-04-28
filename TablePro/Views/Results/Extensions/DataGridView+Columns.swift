//
//  DataGridView+Columns.swift
//  TablePro
//

import AppKit
import SwiftUI

extension TableViewCoordinator {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }

        let columnId = column.identifier.rawValue
        let tableRows = tableRowsProvider()

        if columnId == "__rowNumber__" {
            return cellFactory.makeRowNumberCell(
                tableView: tableView,
                row: row,
                cachedRowCount: tableRows.count,
                visualState: visualState(for: row)
            )
        }

        guard let columnIndex = DataGridView.dataColumnIndex(from: column.identifier) else { return nil }

        guard row >= 0 && row < tableRows.count,
              columnIndex >= 0 && columnIndex < cachedColumnCount else {
            return nil
        }

        let rawValue = tableRows.value(at: row, column: columnIndex)
        let displayValue = resolveDisplayValue(
            row: row,
            columnIndex: columnIndex,
            rawValue: rawValue,
            tableRows: tableRows
        )
        let state = visualState(for: row)

        let tableColumnIndex = DataGridView.tableColumnIndex(for: columnIndex)
        let isFocused: Bool = {
            guard let keyTableView = tableView as? KeyHandlingTableView,
                  keyTableView.focusedRow == row,
                  keyTableView.focusedColumn == tableColumnIndex else { return false }
            return true
        }()

        let isDropdown = dropdownColumns?.contains(columnIndex) == true
        let isTypePicker = typePickerColumns?.contains(columnIndex) == true

        let isEnumOrSet = enumOrSetColumns.contains(columnIndex)
        let isFKColumn = fkColumns.contains(columnIndex)

        let hasSpecialEditor: Bool = {
            guard columnIndex < rowProvider.columnTypes.count else { return false }
            let ct = rowProvider.columnTypes[columnIndex]
            return ct.isBooleanType || ct.isDateType || ct.isJsonType || ct.isBlobType
        }()

        return cellFactory.makeDataCell(
            tableView: tableView,
            row: row,
            columnIndex: columnIndex,
            displayValue: displayValue,
            rawValue: rawValue,
            visualState: state,
            isEditable: isEditable && !state.isDeleted,
            isLargeDataset: isLargeDataset,
            isFocused: isFocused,
            isDropdown: isEditable && (isDropdown || isTypePicker || isEnumOrSet || hasSpecialEditor),
            isFKColumn: isFKColumn && !isDropdown && !(typePickerColumns?.contains(columnIndex) == true),
            fkArrowTarget: self,
            fkArrowAction: #selector(handleFKArrowClick(_:)),
            chevronTarget: self,
            chevronAction: #selector(handleChevronClick(_:)),
            delegate: self
        )
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let delegateRowView = delegate?.dataGridRowView(for: tableView, row: row, coordinator: self) {
            return delegateRowView
        }
        let rowView = (tableView.makeView(withIdentifier: Self.rowViewIdentifier, owner: nil) as? TableRowViewWithMenu)
            ?? TableRowViewWithMenu()
        rowView.identifier = Self.rowViewIdentifier
        rowView.coordinator = self
        rowView.rowIndex = row
        return rowView
    }

    private func resolveDisplayValue(
        row: Int,
        columnIndex: Int,
        rawValue: String?,
        tableRows: TableRows
    ) -> String? {
        if row < rowProvider.totalRowCount {
            return rowProvider.displayValue(atRow: row, column: columnIndex)
        }
        let columnType = columnIndex < tableRows.columnTypes.count
            ? tableRows.columnTypes[columnIndex]
            : nil
        let displayFormat = columnIndex < rowProvider.columnDisplayFormats.count
            ? rowProvider.columnDisplayFormats[columnIndex]
            : nil
        return CellDisplayFormatter.format(rawValue, columnType: columnType, displayFormat: displayFormat)
    }
}
