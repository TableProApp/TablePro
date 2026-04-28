//
//  DataGridView+CellCommit.swift
//  TablePro
//

import AppKit

extension TableViewCoordinator {
    func commitCellEdit(row: Int, columnIndex: Int, newValue: String?) {
        guard let tableView else { return }
        guard columnIndex >= 0 && columnIndex < rowProvider.columns.count else { return }

        let storageRow = tableRowsIndex(forDisplayRow: row)
        let displayRowValues = displayRow(at: row)
        let usesTableRows = storageRow != nil && displayRowValues != nil
        let oldValue: String? = {
            if let displayRowValues, columnIndex < displayRowValues.values.count {
                return displayRowValues.values[columnIndex]
            }
            return rowProvider.value(atRow: row, column: columnIndex)
        }()
        guard oldValue != newValue else { return }

        let columnName = rowProvider.columns[columnIndex]
        let originalRow: [String?] = {
            if let displayRowValues {
                return displayRowValues.values
            }
            return rowProvider.rowValues(at: row) ?? []
        }()
        changeManager.recordCellChange(
            rowIndex: row,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: originalRow
        )

        var delta: Delta = .none
        if let storageRow {
            tableRowsMutator { tableRows in
                delta = tableRows.edit(row: storageRow, column: columnIndex, value: newValue)
            }
        }
        delegate?.dataGridDidEditCell(row: row, column: columnIndex, newValue: newValue)
        rowProvider.invalidateDisplayCache()

        if usesTableRows, case .cellChanged = delta {
            let displayDelta: Delta = .cellChanged(
                row: row,
                column: DataGridView.tableColumnIndex(for: columnIndex)
            )
            tableRowsController.apply(displayDelta)
        } else {
            let tableColumnIndex = DataGridView.tableColumnIndex(for: columnIndex)
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integer: tableColumnIndex)
            )
        }
    }
}
