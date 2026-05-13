//
//  DataGridView+CellCommit.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension TableViewCoordinator {
    func commitCellEdit(row: Int, columnIndex: Int, newValue: String?) {
        commitTypedCellEdit(row: row, columnIndex: columnIndex, newValue: PluginCellValue.fromOptional(newValue))
    }

    func commitTypedCellEdit(row: Int, columnIndex: Int, newValue typedNewValue: PluginCellValue) {
        guard !isCommittingCellEdit else { return }
        guard let tableView else { return }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0 && columnIndex < tableRows.columns.count else { return }
        guard let displayRowValues = displayRow(at: row) else { return }
        guard columnIndex < displayRowValues.values.count else { return }
        let oldValue = displayRowValues.values[columnIndex]
        guard oldValue != typedNewValue else { return }

        isCommittingCellEdit = true
        defer { isCommittingCellEdit = false }

        let storageRow = tableRowsIndex(forDisplayRow: row)
        let columnName = tableRows.columns[columnIndex]
        let originalRow = Array(displayRowValues.values)
        changeManager.recordCellChange(
            rowIndex: row,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: typedNewValue,
            originalRow: originalRow
        )

        var delta: Delta = .none
        if let storageRow {
            tableRowsMutator { tableRows in
                delta = tableRows.edit(row: storageRow, column: columnIndex, value: typedNewValue)
            }
        }
        delegate?.dataGridDidEditCell(row: row, column: columnIndex, newValue: typedNewValue.asText)
        invalidateDisplayCache()
        visualIndex.updateRow(row, from: changeManager, sortedIDs: sortedIDs)

        guard let tableColumnIndex = DataGridView.tableColumnIndex(
            for: columnIndex,
            in: tableView,
            schema: identitySchema
        ) else { return }
        if storageRow != nil, case .cellChanged = delta {
            tableRowsController.apply(.cellChanged(row: row, column: tableColumnIndex))
        } else {
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integer: tableColumnIndex)
            )
        }
    }
}
