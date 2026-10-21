//
//  DataGridView+CellCommit.swift
//  TablePro
//

import AppKit
import os
import TableProPluginKit

private let cellCommitLogger = Logger(subsystem: "com.TablePro", category: "DataGrid")

extension TableViewCoordinator {
    /// Every caller hands over text a person entered, so it is read for the column it lands in:
    /// an emptied date, number or boolean is NULL, an emptied text cell is `''`. A NOT NULL column
    /// that can hold neither keeps its value, and the beep says the edit was refused.
    func commitCellEdit(row: Int, columnIndex: Int, newValue: String?) {
        if !commitEnteredText(newValue, row: row, columnIndex: columnIndex) {
            NSSound.beep()
        }
    }

    /// False when the column holds neither the text nor NULL in its place, and nothing was staged.
    @discardableResult
    func commitEnteredText(_ text: String?, row: Int, columnIndex: Int) -> Bool {
        guard let entry = enteredCell(text, columnIndex: columnIndex) else { return false }
        commitTypedCellEdit(row: row, columnIndex: columnIndex, newValue: entry.value, isExpression: entry.isExpression)
        return true
    }

    /// A function the engine runs on this kind of column stages as SQL; anything else is read for the column as
    /// `TableRows.enteredValue` reads it.
    func enteredCell(_ text: String?, columnIndex: Int) -> (value: PluginCellValue, isExpression: Bool)? {
        let tableRows = tableRowsProvider()
        if let text, let databaseType,
           let expression = CellEntry.typed(
               text,
               columnType: tableRows.editingColumnType(at: columnIndex),
               databaseType: databaseType,
               writer: changeManager.cellWriterSupport
           ) {
            return expression
        }
        return tableRows.enteredValue(text, forColumn: columnIndex).map { (value: $0, isExpression: false) }
    }

    func commitTypedCellEdit(
        row: Int,
        columnIndex: Int,
        newValue typedNewValue: PluginCellValue,
        isExpression: Bool = false
    ) {
        guard recordCellEdit(
            row: row, columnIndex: columnIndex, newValue: typedNewValue, isExpression: isExpression
        ) != nil else { return }
        repaintEditedCell(row: row, columnIndex: columnIndex)
    }

    /// Takes the field out of the row, for an engine that tells a missing field from NULL.
    func removeField(row: Int, columnIndex: Int) {
        guard supportsFieldRemoval,
              recordCellEdit(row: row, columnIndex: columnIndex, newValue: .null, removesField: true) != nil
        else { return }
        repaintEditedCell(row: row, columnIndex: columnIndex)
    }

    func repaintEditedCell(row: Int, columnIndex: Int) {
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
        guard let entry = enteredCell(newValue, columnIndex: columnIndex) else {
            NSSound.beep()
            return
        }
        commitTypedCellEdit(
            rowID: rowID, columnIndex: columnIndex, newValue: entry.value, isExpression: entry.isExpression
        )
    }

    func commitTypedCellEdit(
        rowID: RowID,
        columnIndex: Int,
        newValue typedNewValue: PluginCellValue,
        isExpression: Bool = false
    ) {
        guard recordCellEdit(
            rowID: rowID, columnIndex: columnIndex, newValue: typedNewValue, isExpression: isExpression
        ) != nil else { return }

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
    func recordCellEdit(
        rowID: RowID,
        columnIndex: Int,
        newValue typedNewValue: PluginCellValue,
        isExpression: Bool = false
    ) -> Delta? {
        let tableRows = tableRowsProvider()
        guard let storageRow = tableRows.index(of: rowID), storageRow < tableRows.rows.count else { return nil }
        return recordCellEdit(
            in: tableRows.rows[storageRow],
            columnIndex: columnIndex,
            newValue: typedNewValue,
            removesField: false,
            isExpression: isExpression,
            displayRow: DisplayRowMapping.displayIndex(forRowID: rowID, displayIDs: displayIDs, in: tableRows)
        )
    }

    @discardableResult
    func recordCellEdit(
        row: Int,
        columnIndex: Int,
        newValue typedNewValue: PluginCellValue,
        removesField: Bool = false,
        isExpression: Bool = false
    ) -> Delta? {
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
            in: displayRowValues,
            columnIndex: columnIndex,
            newValue: typedNewValue,
            removesField: removesField,
            isExpression: isExpression,
            displayRow: row
        )
    }

    /// The one place a cell edit becomes a pending change and a new value in the shared row buffer.
    /// `displayRow` is only what the delegate is told; the record and the write are by identity.
    ///
    /// A value written into a missing field brings the field back, and `removesField` takes it out,
    /// so NULL over a missing field is an edit even though both read `.null`. An expression over text that
    /// reads the same is an edit too, and so is the text over the expression.
    @discardableResult
    private func recordCellEdit(
        in row: Row,
        columnIndex: Int,
        newValue typedNewValue: PluginCellValue,
        removesField: Bool,
        isExpression: Bool,
        displayRow: Int?
    ) -> Delta? {
        guard !isCommittingCellEdit else { return nil }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return nil }
        guard isColumnWritable(tableRows.columns[columnIndex]) else { return nil }
        guard columnIndex < row.values.count else { return nil }
        // Its `.null` stands for a value still on the server, which no edit may replace unread.
        guard row.unloadedByteCount(columnIndex) == nil else {
            NSSound.beep()
            return nil
        }
        let oldValue = row.values[columnIndex]
        let absence = FieldAbsence(
            wasAbsent: row.isAbsent(columnIndex),
            isAbsent: removesField,
            originalRow: row.absentColumns
        )
        let wasExpression = changeManager.isExpression(rowID: row.id, columnIndex: columnIndex)
        guard oldValue != typedNewValue || absence.wasAbsent != absence.isAbsent || wasExpression != isExpression
        else {
            cellCommitLogger.debug("recordCellEdit - value unchanged, guard returned")
            return nil
        }

        isCommittingCellEdit = true
        defer { isCommittingCellEdit = false }

        let rowID = row.id
        changeManager.recordCellChange(
            rowID: rowID,
            columnIndex: columnIndex,
            columnName: tableRows.columns[columnIndex],
            oldValue: oldValue,
            newValue: typedNewValue,
            originalRow: Array(row.values),
            absence: absence,
            isExpression: isExpression
        )

        var delta: Delta = .none
        if let storageRow = tableRows.index(of: rowID) {
            delta = tableRowsMutator { tableRows in
                tableRows.edit(row: storageRow, column: columnIndex, value: typedNewValue, isAbsent: removesField)
            }
        }
        selectionSummaryTracker.dataDidChange()
        /// A record the display order is hiding has no row to report, and every delegate reads that
        /// argument as a display position.
        if let displayRow {
            delegate?.dataGridDidEditCell(row: displayRow, column: columnIndex, newValue: typedNewValue.asText)
        }
        return delta
    }
}
