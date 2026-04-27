//
//  DataGridView+CellCommit.swift
//  TablePro
//

import AppKit

extension TableViewCoordinator {
    func commitCellEdit(row: Int, columnIndex: Int, newValue: String?) {
        guard let tableView else { return }
        guard columnIndex >= 0 && columnIndex < rowProvider.columns.count else { return }

        let oldValue = rowProvider.value(atRow: row, column: columnIndex)
        guard oldValue != newValue else { return }

        let columnName = rowProvider.columns[columnIndex]
        changeManager.recordCellChange(
            rowIndex: row,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: rowProvider.rowValues(at: row) ?? []
        )

        rowProvider.updateValue(newValue, at: row, columnIndex: columnIndex)
        delegate?.dataGridDidEditCell(row: row, column: columnIndex, newValue: newValue)

        let tableColumnIndex = DataGridView.tableColumnIndex(for: columnIndex)
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: tableColumnIndex)
        )
    }
}
