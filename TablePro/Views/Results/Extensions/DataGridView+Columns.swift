//
//  DataGridView+Columns.swift
//  TablePro
//

import AppKit
import SwiftUI

extension TableViewCoordinator {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }

        let tableRows = tableRowsProvider()
        let displayCount = sortedIDs?.count ?? tableRows.count

        if column.identifier == ColumnIdentitySchema.rowNumberIdentifier {
            return cellFactory.makeRowNumberCell(
                tableView: tableView,
                row: row,
                cachedRowCount: displayCount,
                visualState: visualState(for: row)
            )
        }

        guard let columnIndex = dataColumnIndex(from: column.identifier) else { return nil }

        guard row >= 0 && row < displayCount,
              columnIndex >= 0 && columnIndex < cachedColumnCount else {
            return nil
        }

        guard let displayRow = displayRow(at: row),
              columnIndex < displayRow.values.count else {
            return nil
        }
        let rawValue = displayRow.values[columnIndex]
        let columnType = columnIndex < tableRows.columnTypes.count
            ? tableRows.columnTypes[columnIndex]
            : nil
        let formattedValue = displayValue(
            forID: displayRow.id,
            column: columnIndex,
            rawValue: rawValue,
            columnType: columnType
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
            guard columnIndex < tableRows.columnTypes.count else { return false }
            let ct = tableRows.columnTypes[columnIndex]
            return ct.isBooleanType || ct.isDateType || ct.isJsonType || ct.isBlobType
        }()

        return cellFactory.makeDataCell(
            tableView: tableView,
            row: row,
            columnIndex: columnIndex,
            displayValue: formattedValue,
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
}
