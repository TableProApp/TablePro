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

        if columnId == "__rowNumber__" {
            return cellFactory.makeRowNumberCell(
                tableView: tableView,
                row: row,
                cachedRowCount: cachedRowCount,
                visualState: visualState(for: row)
            )
        }

        guard columnId.hasPrefix("col_"), let columnIndex = Int(columnId.dropFirst(4)) else { return nil }

        guard row >= 0 && row < cachedRowCount,
              columnIndex >= 0 && columnIndex < cachedColumnCount else {
            return nil
        }

        let rawValue = rowProvider.value(atRow: row, column: columnIndex)
        let displayValue = rowProvider.displayValue(atRow: row, column: columnIndex)
        let state = visualState(for: row)

        let tableColumnIndex = columnIndex + 1
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
        if let provider = rowViewProvider {
            return provider(tableView, row, self)
        }
        let rowView = (tableView.makeView(withIdentifier: Self.rowViewIdentifier, owner: nil) as? TableRowViewWithMenu)
            ?? TableRowViewWithMenu()
        rowView.identifier = Self.rowViewIdentifier
        rowView.coordinator = self
        rowView.rowIndex = row
        return rowView
    }
}
