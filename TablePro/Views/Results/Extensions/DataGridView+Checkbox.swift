//
//  DataGridView+Checkbox.swift
//  TablePro
//

import AppKit

extension TableViewCoordinator {
    func presentsCheckboxCell(columnIndex: Int) -> Bool {
        checkboxColumns.contains(columnIndex)
    }

    func checkboxMark(row: Int, columnIndex: Int) -> DataGridCheckboxMark? {
        guard presentsCheckboxCell(columnIndex: columnIndex),
              let isOn = delegate?.dataGridCheckboxState(row: row, column: columnIndex) else { return nil }
        return isOn ? .checked : .unchecked
    }

    @discardableResult
    func toggleCheckbox(row: Int, columnIndex: Int) -> Bool {
        guard let mark = checkboxMark(row: row, columnIndex: columnIndex) else { return false }
        delegate?.dataGridSetCheckbox(mark == .unchecked, rows: IndexSet(integer: row), column: columnIndex)
        invalidateRowDecoration(displayRow: row)
        return true
    }

    /// Space over a selection sets every selected checkbox the same way, the way a list of mail
    /// messages marks them: on unless every one is already on.
    func toggleCheckboxesForSelection() -> Bool {
        guard let column = checkboxColumns.min(), let tableView else { return false }
        /// A rectangular cell selection keeps the table view pinned to its anchor row, so the rows
        /// the grid is showing as selected come from the cell selection when there is one.
        let cellRows = selectionController.selection.affectedRows
        let selected = cellRows.isEmpty ? IndexSet(tableView.selectedRowIndexes) : cellRows
        let rows = selected.filter { checkboxMark(row: $0, columnIndex: column) != nil }
        guard !rows.isEmpty else { return false }
        let everyRowChecked = rows.allSatisfy { checkboxMark(row: $0, columnIndex: column) == .checked }
        delegate?.dataGridSetCheckbox(!everyRowChecked, rows: IndexSet(rows), column: column)
        for row in rows {
            invalidateRowDecoration(displayRow: row)
        }
        return true
    }
}
