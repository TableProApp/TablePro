//
//  PendingChanges.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct PendingChanges: Equatable {
    private(set) var changes: [RowChange] = []
    private(set) var deletedRowIDs: Set<RowID> = []

    // `changes` cannot carry the edit order: a cancelled change is swap-removed from it.
    private var nextSequence = 0
    private(set) var insertedRowIDs: Set<RowID> = []
    private(set) var modifiedCells: [RowID: Set<Int>] = [:]
    private(set) var insertedRowData: [RowID: [PluginCellValue]] = [:]

    // A deleted row's edits, parked so the delete keys on the row as read and undoing it brings them back.
    private(set) var supersededUpdates: [RowID: RowChange] = [:]

    private var changeIndex: [RowChangeKey: Int] = [:]

    var isEmpty: Bool { changes.isEmpty }
    var hasChanges: Bool { !isEmpty }

    // MARK: - Read

    func isRowDeleted(_ rowID: RowID) -> Bool {
        deletedRowIDs.contains(rowID)
    }

    func isRowInserted(_ rowID: RowID) -> Bool {
        insertedRowIDs.contains(rowID)
    }

    func isCellModified(rowID: RowID, columnIndex: Int) -> Bool {
        modifiedCells[rowID]?.contains(columnIndex) == true
    }

    func modifiedColumns(forRow rowID: RowID) -> Set<Int> {
        modifiedCells[rowID] ?? []
    }

    mutating func adoptLoadedValues(_ values: [RowID: [Int: PluginCellValue]]) {
        RowChange.adoptLoadedValues(values, into: &changes)
    }

    // `current` is the row as the grid holds it, pending edits included.
    func imageAsRead(
        ofRow rowID: RowID,
        current: [PluginCellValue],
        absentColumns: Set<Int>
    ) -> (row: [PluginCellValue], absentColumns: Set<Int>) {
        guard let update = change(forRow: rowID, type: .update) else { return (current, absentColumns) }
        var row = current
        var absent = absentColumns
        for cellChange in update.cellChanges where row.indices.contains(cellChange.columnIndex) {
            row[cellChange.columnIndex] = cellChange.oldValue
            if cellChange.oldIsAbsent {
                absent.insert(cellChange.columnIndex)
            } else {
                absent.remove(cellChange.columnIndex)
            }
        }
        return (row, absent)
    }

    func change(forRow rowID: RowID, type: ChangeType) -> RowChange? {
        guard let idx = changeIndex[RowChangeKey(rowID: rowID, type: type)] else { return nil }
        return changes[idx]
    }

    // The row's change that comes first in `changes`, which is what a scan for its id would find.
    func firstChange(forRow rowID: RowID) -> RowChange? {
        var first: Int?
        for type in [ChangeType.insert, .update, .delete] {
            guard let idx = changeIndex[RowChangeKey(rowID: rowID, type: type)] else { continue }
            first = min(first ?? idx, idx)
        }
        return first.map { changes[$0] }
    }

    /// The row's cells that hold a SQL expression now: a new row's from its insert, a saved row's from its edits.
    func expressionColumns(forRow rowID: RowID) -> Set<Int> {
        if let insert = change(forRow: rowID, type: .insert) {
            return insert.expressionColumns
        }
        guard let update = change(forRow: rowID, type: .update) else { return [] }
        return Set(update.cellChanges.lazy.filter(\.newIsExpression).map(\.columnIndex))
    }

    func isExpression(rowID: RowID, columnIndex: Int) -> Bool {
        if let insert = change(forRow: rowID, type: .insert) {
            return insert.expressionColumns.contains(columnIndex)
        }
        return change(forRow: rowID, type: .update)?
            .cellChanges.first { $0.columnIndex == columnIndex }?.newIsExpression ?? false
    }

    // MARK: - Mutate (recording user edits)

    // False for a no-op, so no undo is registered. A nil `action` is an undo step of its own.
    @discardableResult
    mutating func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]? = nil,
        absence: FieldAbsence = FieldAbsence(),
        isExpression: Bool = false,
        action: Int? = nil
    ) -> Bool {
        let wasExpression = self.isExpression(rowID: rowID, columnIndex: columnIndex)
        if oldValue == newValue && absence.wasAbsent == absence.isAbsent && wasExpression == isExpression {
            return rollbackCellIfMatchesOriginal(
                rowID: rowID, columnIndex: columnIndex, restoredValue: newValue, restoredIsAbsent: absence.isAbsent,
                restoredIsExpression: isExpression
            )
        }

        let cellChange = CellChange(
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            oldIsAbsent: absence.wasAbsent,
            newIsAbsent: absence.isAbsent,
            oldIsExpression: wasExpression,
            newIsExpression: isExpression
        )

        if let insertIdx = changeIndex[RowChangeKey(rowID: rowID, type: .insert)] {
            updateInsertedCell(
                at: insertIdx, columnIndex: columnIndex, columnName: columnName, newValue: newValue,
                isAbsent: absence.isAbsent, isExpression: isExpression
            )
            return true
        }

        if let updateIdx = changeIndex[RowChangeKey(rowID: rowID, type: .update)] {
            mergeUpdateCell(at: updateIdx, cellChange: cellChange, action: action)
        } else {
            appendUpdate(
                rowID: rowID, cellChange: cellChange, originalRow: originalRow,
                absentColumns: absence.originalRow, action: action
            )
        }
        return true
    }

    mutating func recordRowDeletion(rowID: RowID, originalRow: [PluginCellValue], absentColumns: Set<Int> = []) {
        guard !deletedRowIDs.contains(rowID) else { return }
        let image = imageAsRead(ofRow: rowID, current: originalRow, absentColumns: absentColumns)
        if let updateIdx = changeIndex[RowChangeKey(rowID: rowID, type: .update)] {
            supersededUpdates[rowID] = changes[updateIdx]
            removeChangeAt(updateIdx)
        }
        modifiedCells.removeValue(forKey: rowID)
        appendChange(RowChange(rowID: rowID, type: .delete, originalRow: image.row, absentColumns: image.absentColumns))
        deletedRowIDs.insert(rowID)
    }

    mutating func recordRowInsertion(
        rowID: RowID,
        values: [PluginCellValue],
        absentColumns: Set<Int> = [],
        expressionColumns: Set<Int> = []
    ) {
        guard !insertedRowIDs.contains(rowID) else {
            insertedRowData[rowID] = values
            if let insertIdx = changeIndex[RowChangeKey(rowID: rowID, type: .insert)] {
                changes[insertIdx].absentColumns = absentColumns
                changes[insertIdx].expressionColumns = expressionColumns
            }
            return
        }
        insertedRowData[rowID] = values
        appendChange(RowChange(
            rowID: rowID, type: .insert, cellChanges: [],
            absentColumns: absentColumns, expressionColumns: expressionColumns
        ))
        insertedRowIDs.insert(rowID)
    }

    // MARK: - Mutate (cancelling pending edits)

    mutating func undoRowDeletion(rowID: RowID) -> Bool {
        guard deletedRowIDs.contains(rowID) else { return false }
        removeChange(rowID: rowID, type: .delete)
        deletedRowIDs.remove(rowID)
        let updateKey = RowChangeKey(rowID: rowID, type: .update)
        if let update = supersededUpdates.removeValue(forKey: rowID), changeIndex[updateKey] == nil {
            // Appended as it was, so it keeps the place in the save order its first edit had.
            changes.append(update)
            changeIndex[updateKey] = changes.count - 1
            modifiedCells[rowID] = Set(update.cellChanges.map(\.columnIndex))
        }
        return true
    }

    mutating func undoRowInsertion(rowID: RowID) -> Bool {
        guard insertedRowIDs.contains(rowID) else { return false }
        removeChange(rowID: rowID, type: .insert)
        insertedRowIDs.remove(rowID)
        insertedRowData.removeValue(forKey: rowID)
        return true
    }

    /// Undo a batch of inserted rows. Returns the saved values for each row in the same order.
    mutating func undoBatchRowInsertion(rowIDs: [RowID], columnCount: Int) -> [[PluginCellValue]] {
        let validRows = rowIDs.filter { insertedRowIDs.contains($0) }

        /// `insertedRowData` holds the whole row. `cellChanges` holds only the columns the user
        /// typed, so rebuilding from it drops the untouched ones and slides the rest left: a name
        /// typed into the third column comes back in the first.
        let rowValues = validRows.map { rowID in
            insertedRowData[rowID] ?? Array(repeating: PluginCellValue.null, count: columnCount)
        }

        for rowID in validRows {
            _ = undoRowInsertion(rowID: rowID)
        }
        return rowValues
    }

    // MARK: - Replay (driven by NSUndoManager invocation)

    /// Re-apply a deletion during undo replay (skips undo registration).
    mutating func reapplyRowDeletion(rowID: RowID, originalRow: [PluginCellValue], absentColumns: Set<Int> = []) {
        recordRowDeletion(rowID: rowID, originalRow: originalRow, absentColumns: absentColumns)
    }

    // `originalDBValue` is the cell as it stands before this write.
    mutating func reapplyCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        originalDBValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?,
        absence: FieldAbsence = FieldAbsence(),
        expression: ExpressionTransition = ExpressionTransition(),
        action: Int? = nil
    ) {
        let cellChange = CellChange(
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: originalDBValue,
            newValue: newValue,
            oldIsAbsent: absence.wasAbsent,
            newIsAbsent: absence.isAbsent,
            oldIsExpression: expression.wasExpression,
            newIsExpression: expression.isExpression
        )

        if let insertIdx = changeIndex[RowChangeKey(rowID: rowID, type: .insert)] {
            updateInsertedCell(
                at: insertIdx, columnIndex: columnIndex, columnName: columnName, newValue: newValue,
                isAbsent: absence.isAbsent, isExpression: expression.isExpression
            )
            return
        }

        if let updateIdx = changeIndex[RowChangeKey(rowID: rowID, type: .update)] {
            mergeUpdateCell(at: updateIdx, cellChange: cellChange, action: action)
        } else {
            appendUpdate(
                rowID: rowID, cellChange: cellChange, originalRow: originalRow,
                absentColumns: absence.originalRow, action: action
            )
        }
    }

    /// Replace an inserted row's cell value during undo replay (no undo).
    mutating func updateInsertedCellDirectly(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        newValue: PluginCellValue,
        isAbsent: Bool = false,
        isExpression: Bool = false
    ) {
        guard let insertIdx = changeIndex[RowChangeKey(rowID: rowID, type: .insert)] else { return }
        updateInsertedCell(
            at: insertIdx, columnIndex: columnIndex, columnName: columnName, newValue: newValue,
            isAbsent: isAbsent, isExpression: isExpression
        )
    }

    // Undo takes back the cell's latest write, which the newest run holding the cell made.
    mutating func revertCellWrite(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        previousValue: PluginCellValue,
        previousIsAbsent: Bool = false,
        previousIsExpression: Bool = false
    ) {
        guard let updateIdx = changeIndex[RowChangeKey(rowID: rowID, type: .update)],
              let current = changes[updateIdx].cellChanges.first(where: { $0.columnIndex == columnIndex })
        else { return }

        materializeRuns(at: updateIdx)
        let reverted = CellChange(
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: current.newValue,
            newValue: previousValue,
            oldIsAbsent: current.newIsAbsent,
            newIsAbsent: previousIsAbsent,
            oldIsExpression: current.newIsExpression,
            newIsExpression: previousIsExpression
        )
        guard writeNetCell(reverted, at: updateIdx),
              let runIdx = changes[updateIdx].runs.lastIndex(where: { $0.holds(columnIndex) })
        else { return }
        write(reverted, intoRun: runIdx, at: updateIdx)
    }

    /// Insert a synthetic .insert RowChange for undo replay (e.g., after redoing a deletion's undo).
    mutating func reinsertRow(
        rowID: RowID,
        columns: [String],
        savedValues: [PluginCellValue]?,
        absentColumns: Set<Int> = [],
        expressionColumns: Set<Int> = []
    ) {
        insertedRowIDs.insert(rowID)
        let cellChanges = columns.enumerated().map { index, columnName in
            CellChange(
                columnIndex: index, columnName: columnName,
                oldValue: nil, newValue: savedValues?[safe: index] ?? nil,
                newIsAbsent: absentColumns.contains(index),
                newIsExpression: expressionColumns.contains(index)
            )
        }
        appendChange(RowChange(
            rowID: rowID, type: .insert, cellChanges: cellChanges,
            absentColumns: absentColumns, expressionColumns: expressionColumns
        ))
        if let savedValues {
            insertedRowData[rowID] = savedValues
        }
    }

    /// Insert a batch of rows (for undo replay of a batch deletion's undo).
    mutating func reinsertBatch(
        rowIDs: [RowID],
        rowValues: [[PluginCellValue]],
        rowAbsentColumns: [Set<Int>] = [],
        rowExpressionColumns: [Set<Int>] = [],
        columns: [String]
    ) {
        for (offset, (rowID, values)) in zip(rowIDs, rowValues).enumerated() {
            let absentColumns = rowAbsentColumns[safe: offset] ?? []
            let expressionColumns = rowExpressionColumns[safe: offset] ?? []
            let cellChanges = values.enumerated().map { colIndex, value in
                CellChange(
                    columnIndex: colIndex,
                    columnName: columns[safe: colIndex] ?? "",
                    oldValue: nil, newValue: value,
                    newIsAbsent: absentColumns.contains(colIndex),
                    newIsExpression: expressionColumns.contains(colIndex)
                )
            }
            appendChange(RowChange(
                rowID: rowID, type: .insert, cellChanges: cellChanges,
                absentColumns: absentColumns, expressionColumns: expressionColumns
            ))
            insertedRowIDs.insert(rowID)
            insertedRowData[rowID] = values
        }
    }

    /// Save inserted-row values for a redo replay closure that may need them.
    func savedInsertedValues(forRow rowID: RowID) -> [PluginCellValue]? {
        insertedRowData[rowID]
    }

    /// The columns an inserted row has no field for, saved beside its values for the same replay.
    func insertedAbsentColumns(forRow rowID: RowID) -> Set<Int> {
        change(forRow: rowID, type: .insert)?.absentColumns ?? []
    }

    func insertedExpressionColumns(forRow rowID: RowID) -> Set<Int> {
        change(forRow: rowID, type: .insert)?.expressionColumns ?? []
    }

    // MARK: - Reset / persistence

    mutating func clear() {
        nextSequence = 0
        changes.removeAll()
        changeIndex.removeAll()
        deletedRowIDs.removeAll()
        insertedRowIDs.removeAll()
        modifiedCells.removeAll()
        insertedRowData.removeAll()
        supersededUpdates.removeAll()
    }

    // MARK: - Internals

    private mutating func appendChange(_ change: RowChange) {
        var stamped = change
        stamped.sequence = nextSequence
        nextSequence += 1
        changes.append(stamped)
        changeIndex[RowChangeKey(rowID: stamped.rowID, type: stamped.type)] = changes.count - 1
    }

    private mutating func appendUpdate(
        rowID: RowID,
        cellChange: CellChange,
        originalRow: [PluginCellValue]?,
        absentColumns: Set<Int>,
        action: Int?
    ) {
        let run = UpdateRun(
            sequence: nextSequence, action: action ?? Self.ownAction(at: nextSequence), cellChanges: [cellChange]
        )
        appendChange(RowChange(
            rowID: rowID, type: .update,
            cellChanges: [cellChange], originalRow: originalRow,
            absentColumns: absentColumns, runs: [run]
        ))
        modifiedCells[rowID, default: []].insert(cellChange.columnIndex)
    }

    // Below every id DataChangeManager hands out, so no other write ever joins it.
    private static func ownAction(at sequence: Int) -> Int {
        -(sequence + 1)
    }

    @discardableResult
    private mutating func removeChange(rowID: RowID, type: ChangeType) -> Bool {
        let key = RowChangeKey(rowID: rowID, type: type)
        guard let arrayIndex = changeIndex[key] else { return false }
        removeChangeAt(arrayIndex)
        return true
    }

    private mutating func removeChangeAt(_ arrayIndex: Int) {
        let removed = changes[arrayIndex]
        changeIndex.removeValue(forKey: RowChangeKey(rowID: removed.rowID, type: removed.type))

        let lastIndex = changes.count - 1
        if arrayIndex != lastIndex {
            let moved = changes[lastIndex]
            changes.swapAt(arrayIndex, lastIndex)
            changeIndex[RowChangeKey(rowID: moved.rowID, type: moved.type)] = arrayIndex
        }
        changes.removeLast()
    }

    private mutating func removeModifiedCell(rowID: RowID, columnIndex: Int) {
        modifiedCells[rowID]?.remove(columnIndex)
        if modifiedCells[rowID]?.isEmpty == true {
            modifiedCells.removeValue(forKey: rowID)
        }
    }

    private mutating func updateInsertedCell(
        at insertIdx: Int,
        columnIndex: Int,
        columnName: String,
        newValue: PluginCellValue,
        isAbsent: Bool,
        isExpression: Bool
    ) {
        let rowID = changes[insertIdx].rowID
        if var stored = insertedRowData[rowID], columnIndex < stored.count {
            stored[columnIndex] = newValue
            insertedRowData[rowID] = stored
        }
        if isAbsent {
            changes[insertIdx].absentColumns.insert(columnIndex)
        } else {
            changes[insertIdx].absentColumns.remove(columnIndex)
        }
        if isExpression {
            changes[insertIdx].expressionColumns.insert(columnIndex)
        } else {
            changes[insertIdx].expressionColumns.remove(columnIndex)
        }

        let replacement = CellChange(
            columnIndex: columnIndex, columnName: columnName,
            oldValue: nil, newValue: newValue, newIsAbsent: isAbsent, newIsExpression: isExpression
        )
        if let cellIdx = changes[insertIdx].cellChanges.firstIndex(where: { $0.columnIndex == columnIndex }) {
            changes[insertIdx].cellChanges[cellIdx] = replacement
        } else {
            changes[insertIdx].cellChanges.append(replacement)
        }
    }

    private mutating func mergeUpdateCell(at updateIdx: Int, cellChange: CellChange, action: Int?) {
        materializeRuns(at: updateIdx)
        guard writeNetCell(cellChange, at: updateIdx) else { return }

        // The newest run takes the write when the same step opened it or nothing was recorded since.
        if let newest = changes[updateIdx].runs.indices.last {
            let run = changes[updateIdx].runs[newest]
            if (action != nil && run.action == action) || run.sequence == nextSequence - 1 {
                write(cellChange, intoRun: newest, at: updateIdx)
                return
            }
        }
        changes[updateIdx].runs.append(UpdateRun(
            sequence: nextSequence, action: action ?? Self.ownAction(at: nextSequence), cellChanges: [cellChange]
        ))
        nextSequence += 1
    }

    // An update built outside this type reads as one run at its own place.
    private mutating func materializeRuns(at updateIdx: Int) {
        let update = changes[updateIdx]
        guard update.runs.isEmpty, !update.cellChanges.isEmpty else { return }
        changes[updateIdx].runs = [UpdateRun(
            sequence: update.sequence, action: Self.ownAction(at: update.sequence), cellChanges: update.cellChanges
        )]
    }

    // False when the write left the cell as it was read, so no run writes it.
    private mutating func writeNetCell(_ cellChange: CellChange, at updateIdx: Int) -> Bool {
        let rowID = changes[updateIdx].rowID
        guard let cellIdx = changes[updateIdx].cellChanges.firstIndex(where: {
            $0.columnIndex == cellChange.columnIndex
        }) else {
            changes[updateIdx].cellChanges.append(cellChange)
            modifiedCells[rowID, default: []].insert(cellChange.columnIndex)
            return true
        }

        let merged = changes[updateIdx].cellChanges[cellIdx].followed(by: cellChange)
        guard merged.restoresOriginal else {
            changes[updateIdx].cellChanges[cellIdx] = merged
            return true
        }
        removeUpdateCell(at: updateIdx, cellIdx: cellIdx)
        return false
    }

    private mutating func write(_ cellChange: CellChange, intoRun runIdx: Int, at updateIdx: Int) {
        changes[updateIdx].runs[runIdx].write(cellChange)
        if changes[updateIdx].runs[runIdx].cellChanges.isEmpty {
            changes[updateIdx].runs.remove(at: runIdx)
        }
    }

    // A cell the grid shows unchanged leaves every run too, so no trigger fires for a value nobody changed.
    private mutating func removeUpdateCell(at updateIdx: Int, cellIdx: Int) {
        let rowID = changes[updateIdx].rowID
        let columnIndex = changes[updateIdx].cellChanges[cellIdx].columnIndex
        changes[updateIdx].cellChanges.remove(at: cellIdx)
        removeModifiedCell(rowID: rowID, columnIndex: columnIndex)
        for runIdx in changes[updateIdx].runs.indices.reversed() {
            changes[updateIdx].runs[runIdx].cellChanges.removeAll { $0.columnIndex == columnIndex }
            if changes[updateIdx].runs[runIdx].cellChanges.isEmpty {
                changes[updateIdx].runs.remove(at: runIdx)
            }
        }
        if changes[updateIdx].cellChanges.isEmpty {
            removeChangeAt(updateIdx)
        }
    }

    @discardableResult
    private mutating func rollbackCellIfMatchesOriginal(
        rowID: RowID,
        columnIndex: Int,
        restoredValue: PluginCellValue,
        restoredIsAbsent: Bool,
        restoredIsExpression: Bool
    ) -> Bool {
        let updateKey = RowChangeKey(rowID: rowID, type: .update)
        guard let updateIdx = changeIndex[updateKey],
              let cellIdx = changes[updateIdx].cellChanges.firstIndex(where: { $0.columnIndex == columnIndex }),
              changes[updateIdx].cellChanges[cellIdx].oldValue == restoredValue,
              changes[updateIdx].cellChanges[cellIdx].oldIsAbsent == restoredIsAbsent,
              changes[updateIdx].cellChanges[cellIdx].oldIsExpression == restoredIsExpression else {
            return false
        }
        removeUpdateCell(at: updateIdx, cellIdx: cellIdx)
        return true
    }
}
