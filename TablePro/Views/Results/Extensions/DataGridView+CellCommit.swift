//
//  DataGridView+CellCommit.swift
//  TablePro
//

import AppKit

extension TableViewCoordinator {
    func commitCellEdit(row: Int, columnIndex: Int, newValue: String?) {
        guard let tableView else { return }
        guard columnIndex >= 0 && columnIndex < rowProvider.columns.count else { return }

        let tableRows = tableRowsProvider()
        let usesTableRows = row >= 0 && row < tableRows.rows.count
        let oldValue: String? = usesTableRows
            ? tableRows.value(at: row, column: columnIndex)
            : rowProvider.value(atRow: row, column: columnIndex)
        guard oldValue != newValue else { return }

        let columnName = rowProvider.columns[columnIndex]
        let originalRow: [String?] = usesTableRows
            ? tableRows.rows[row].values
            : (rowProvider.rowValues(at: row) ?? [])
        changeManager.recordCellChange(
            rowIndex: row,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: originalRow
        )

        var delta: Delta = .none
        tableRowsMutator { tableRows in
            delta = tableRows.edit(row: row, column: columnIndex, value: newValue)
        }
        delegate?.dataGridDidEditCell(row: row, column: columnIndex, newValue: newValue)
        rowProvider.invalidateDisplayCache()

        if usesTableRows, case .cellChanged = delta {
            tableRowsController.apply(translatedColumnDelta(delta))
        } else {
            let tableColumnIndex = DataGridView.tableColumnIndex(for: columnIndex)
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integer: tableColumnIndex)
            )
        }
    }

    private func translatedColumnDelta(_ delta: Delta) -> Delta {
        switch delta {
        case .cellChanged(let row, let column):
            return .cellChanged(row: row, column: DataGridView.tableColumnIndex(for: column))
        case .cellsChanged(let positions):
            let translated = Set(positions.map {
                CellPosition(row: $0.row, column: DataGridView.tableColumnIndex(for: $0.column))
            })
            return .cellsChanged(translated)
        default:
            return delta
        }
    }
}
