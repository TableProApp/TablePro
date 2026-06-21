//
//  DataGridView+CellCommit.swift
//  TablePro
//

import AppKit
import os
import TableProPluginKit

private let cellCommitLogger = Logger(subsystem: "com.TablePro", category: "CSVInspector")

extension TableViewCoordinator {
    func commitCellEdit(row: Int, columnIndex: Int, newValue: String?) {
        commitTypedCellEdit(row: row, columnIndex: columnIndex, newValue: PluginCellValue.fromOptional(newValue))
    }

    func commitTypedCellEdit(row: Int, columnIndex: Int, newValue typedNewValue: PluginCellValue) {
        guard let tableView else { return }
        guard let delta = recordCellEdit(row: row, columnIndex: columnIndex, newValue: typedNewValue) else { return }

        invalidateDisplayCache()
        visualIndex.updateRow(row, from: changeManager, sortedIDs: sortedIDs)

        guard let tableColumnIndex = tableColumnIndex(for: columnIndex) else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: tableColumnIndex)
        )
    }

    @discardableResult
    func recordCellEdit(row: Int, columnIndex: Int, newValue typedNewValue: PluginCellValue) -> Delta? {
        cellCommitLogger.debug("recordCellEdit(row: \(row, privacy: .public), columnIndex: \(columnIndex, privacy: .public)) isCommitting=\(self.isCommittingCellEdit, privacy: .public) delegate=\(self.delegate == nil ? "nil" : "present", privacy: .public)")
        guard !isCommittingCellEdit else { return nil }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0 && columnIndex < tableRows.columns.count else { return nil }
        guard let displayRowValues = displayRow(at: row) else { return nil }
        guard columnIndex < displayRowValues.values.count else { return nil }
        let oldValue = displayRowValues.values[columnIndex]
        guard oldValue != typedNewValue else {
            cellCommitLogger.debug("recordCellEdit - value unchanged, guard returned")
            return nil
        }

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
        cellCommitLogger.debug("recordCellEdit - about to call delegate.dataGridDidEditCell, delegate=\(self.delegate == nil ? "nil" : "present", privacy: .public)")
        delegate?.dataGridDidEditCell(row: row, column: columnIndex, newValue: typedNewValue.asText)
        return delta
    }
}
