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
            return cellRegistry.makeRowNumberCell(
                in: tableView,
                row: row,
                cachedRowCount: displayCount,
                visualState: visualState(for: row)
            )
        }

        guard let columnIndex = dataColumnIndex(from: column.identifier) else {
            return nil
        }

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

        let isFocused: Bool = {
            guard let keyTableView = tableView as? KeyHandlingTableView,
                  keyTableView.focusedRow == row,
                  let tableColumnIndex = DataGridView.tableColumnIndex(
                    for: columnIndex,
                    in: tableView,
                    schema: identitySchema
                  ),
                  keyTableView.focusedColumn == tableColumnIndex else { return false }
            return true
        }()

        let isDropdown = dropdownColumns?.contains(columnIndex) == true
        let isTypePicker = typePickerColumns?.contains(columnIndex) == true
        let isEnumOrSet = enumOrSetColumns.contains(columnIndex)
        let isFKColumn = fkColumns.contains(columnIndex)
        let resolvedFK = isFKColumn && !isDropdown && !isTypePicker
        let resolvedDropdown = isEditable && (isDropdown || isTypePicker || isEnumOrSet)

        let kind = cellRegistry.resolveKind(
            columnIndex: columnIndex,
            columnType: columnType,
            isFKColumn: resolvedFK,
            isDropdownColumn: resolvedDropdown
        )

        let accessibilityValue = rawValue ?? String(localized: "NULL")
        let content = DataGridCellContent(
            displayText: formattedValue ?? "",
            rawValue: rawValue,
            placeholder: placeholderKind(for: rawValue),
            accessibilityLabel: String(
                format: String(localized: "Row %d, column %d: %@"),
                row + 1,
                columnIndex + 1,
                accessibilityValue
            )
        )
        let cellState = DataGridCellState(
            visualState: state,
            isFocused: isFocused,
            isEditable: isEditable && !state.isDeleted,
            isLargeDataset: isLargeDataset,
            row: row,
            columnIndex: columnIndex
        )

        let cell = cellRegistry.dequeueCell(of: kind, in: tableView)
        cell.configure(content: content, state: cellState)
        return cell
    }

    private func placeholderKind(for rawValue: String?) -> DataGridCellPlaceholder? {
        guard let rawValue else { return .null }
        if rawValue == "__DEFAULT__" { return .defaultMarker }
        if rawValue.isEmpty { return .empty }
        return nil
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
