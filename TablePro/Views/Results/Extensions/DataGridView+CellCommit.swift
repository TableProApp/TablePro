//
//  DataGridView+CellCommit.swift
//  TablePro
//

import AppKit
import os
import TableProPluginKit

private let cellCommitLogger = Logger(subsystem: "com.TablePro", category: "DataGrid")

extension TableViewCoordinator {
    func commitCellEdit(row: Int, columnIndex: Int, newValue: String?) {
        commitTypedCellEdit(row: row, columnIndex: columnIndex, newValue: PluginCellValue.fromOptional(newValue))
    }

    func commitTypedCellEdit(row: Int, columnIndex: Int, newValue typedNewValue: PluginCellValue) {
        guard recordCellEdit(row: row, columnIndex: columnIndex, newValue: typedNewValue) != nil else { return }

        invalidateDisplayCache()
        updateVisualIndex(forDisplayRow: row)

        invalidateRowDecoration(displayRow: row)
        guard let tableColumnIndex = tableColumnIndex(for: columnIndex) else { return }
        redrawCells(rows: IndexSet(integer: row), tableColumnIndexes: IndexSet(integer: tableColumnIndex))
    }

    /// Commits into the record an editor was opened for rather than into whatever now sits at the
    /// display position it was opened from.
    ///
    /// A detached editor outlives a sort, a value filter and a display-format change, none of which
    /// close it, and a display row names a different record after any of them.
    func commitCellEdit(rowID: RowID, columnIndex: Int, newValue: String?) {
        commitTypedCellEdit(rowID: rowID, columnIndex: columnIndex, newValue: PluginCellValue.fromOptional(newValue))
    }

    func commitTypedCellEdit(rowID: RowID, columnIndex: Int, newValue typedNewValue: PluginCellValue) {
        guard recordCellEdit(rowID: rowID, columnIndex: columnIndex, newValue: typedNewValue) != nil else { return }

        invalidateDisplayCache()
        /// A record the value filter is hiding is written and not repainted, because it has no row
        /// on screen to repaint.
        guard let displayRow = DisplayRowMapping.displayIndex(
            forRowID: rowID,
            displayIDs: displayIDs,
            in: tableRowsProvider()
        ) else { return }
        updateVisualIndex(forDisplayRow: displayRow)
        invalidateRowDecoration(displayRow: displayRow)
        guard let tableColumnIndex = tableColumnIndex(for: columnIndex) else { return }
        redrawCells(rows: IndexSet(integer: displayRow), tableColumnIndexes: IndexSet(integer: tableColumnIndex))
    }

    @discardableResult
    func recordCellEdit(rowID: RowID, columnIndex: Int, newValue typedNewValue: PluginCellValue) -> Delta? {
        let tableRows = tableRowsProvider()
        guard let storageRow = tableRows.index(of: rowID), storageRow < tableRows.rows.count else { return nil }
        return recordCellEdit(
            rowID: rowID,
            values: Array(tableRows.rows[storageRow].values),
            columnIndex: columnIndex,
            newValue: typedNewValue,
            displayRow: DisplayRowMapping.displayIndex(forRowID: rowID, displayIDs: displayIDs, in: tableRows)
        )
    }

    @discardableResult
    func recordCellEdit(row: Int, columnIndex: Int, newValue typedNewValue: PluginCellValue) -> Delta? {
        cellCommitLogger.debug("recordCellEdit(row: \(row, privacy: .public), columnIndex: \(columnIndex, privacy: .public)) isCommitting=\(self.isCommittingCellEdit, privacy: .public) delegate=\(self.delegate == nil ? "nil" : "present", privacy: .public)")
        guard !isCommittingCellEdit else { return nil }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0 && columnIndex < tableRows.columns.count else { return nil }
        /// Before the rows are touched, not after. The change manager refuses a server-owned column
        /// on its own, and editing here first would paint a value into the grid that no statement
        /// will ever carry.
        guard isColumnWritable(tableRows.columns[columnIndex]) else { return nil }
        guard let displayRowValues = displayRow(at: row) else { return nil }
        return recordCellEdit(
            rowID: displayRowValues.id,
            values: Array(displayRowValues.values),
            columnIndex: columnIndex,
            newValue: typedNewValue,
            displayRow: row
        )
    }

    /// The one place a cell edit becomes a pending change and a new value in the shared row buffer.
    /// `displayRow` is only what the delegate is told; the record and the write are by identity.
    @discardableResult
    private func recordCellEdit(
        rowID: RowID,
        values: [PluginCellValue],
        columnIndex: Int,
        newValue typedNewValue: PluginCellValue,
        displayRow: Int?
    ) -> Delta? {
        guard !isCommittingCellEdit else { return nil }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return nil }
        guard isColumnWritable(tableRows.columns[columnIndex]) else { return nil }
        guard columnIndex < values.count else { return nil }
        let oldValue = values[columnIndex]
        guard oldValue != typedNewValue else {
            cellCommitLogger.debug("recordCellEdit - value unchanged, guard returned")
            return nil
        }

        isCommittingCellEdit = true
        defer { isCommittingCellEdit = false }

        changeManager.recordCellChange(
            rowID: rowID,
            columnIndex: columnIndex,
            columnName: tableRows.columns[columnIndex],
            oldValue: oldValue,
            newValue: typedNewValue,
            originalRow: values
        )

        var delta: Delta = .none
        if let storageRow = tableRows.index(of: rowID) {
            delta = tableRowsMutator { tableRows in
                tableRows.edit(row: storageRow, column: columnIndex, value: typedNewValue)
            }
        }
        /// A record the display order is hiding has no row to report, and every delegate reads that
        /// argument as a display position.
        if let displayRow {
            delegate?.dataGridDidEditCell(row: displayRow, column: columnIndex, newValue: typedNewValue.asText)
        }
        return delta
    }
}
