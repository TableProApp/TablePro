//
//  PendingChanges.swift
//  TablePro
//
//  Value type holding all uncommitted edits to a result set.
//  Owns the consistency invariants between `changes`, `changeIndex`,
//  `deletedRowIDs`, `insertedRowIDs`, `modifiedCells`, and
//  `insertedRowData`. Callers mutate through methods that maintain
//  the cross-collection state.
//

import Foundation
import TableProPluginKit

struct PendingChanges: Equatable {
    private(set) var changes: [RowChange] = []
    private(set) var deletedRowIDs: Set<RowID> = []

    /// Stamped onto every change so statement generation can recover the order the user worked in.
    /// `changes` cannot carry that order itself: a cancelled change is removed by swapping the last
    /// element into its slot.
    private var nextSequence = 0
    private(set) var insertedRowIDs: Set<RowID> = []
    private(set) var modifiedCells: [RowID: Set<Int>] = [:]
    private(set) var insertedRowData: [RowID: [PluginCellValue]] = [:]

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

    func change(forRow rowID: RowID, type: ChangeType) -> RowChange? {
        guard let idx = changeIndex[RowChangeKey(rowID: rowID, type: type)] else { return nil }
        return changes[idx]
    }

    // MARK: - Mutate (recording user edits)

    /// Whether the recorded edit is a no-op (oldValue == newValue with no prior modification).
    /// Returns the result so the caller can decide whether to register undo.
    @discardableResult
    mutating func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]? = nil
    ) -> Bool {
        if oldValue == newValue {
            return rollbackCellIfMatchesOriginal(
                rowID: rowID, columnIndex: columnIndex, restoredValue: newValue
            )
        }

        let cellChange = CellChange(
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue
        )

        if let insertIdx = changeIndex[RowChangeKey(rowID: rowID, type: .insert)] {
            updateInsertedCell(at: insertIdx, columnIndex: columnIndex,
                               columnName: columnName, newValue: newValue)
            return true
        }

        let updateKey = RowChangeKey(rowID: rowID, type: .update)
        if let updateIdx = changeIndex[updateKey] {
            mergeUpdateCell(at: updateIdx, cellChange: cellChange)
        } else {
            let row = RowChange(
                rowID: rowID, type: .update,
                cellChanges: [cellChange], originalRow: originalRow
            )
            changes.append(row)
            changeIndex[updateKey] = changes.count - 1
            modifiedCells[rowID, default: []].insert(columnIndex)
        }
        return true
    }

    mutating func recordRowDeletion(rowID: RowID, originalRow: [PluginCellValue]) {
        guard !deletedRowIDs.contains(rowID) else { return }
        removeChange(rowID: rowID, type: .update)
        modifiedCells.removeValue(forKey: rowID)
        appendChange(RowChange(rowID: rowID, type: .delete, originalRow: originalRow))
        deletedRowIDs.insert(rowID)
    }

    mutating func recordRowInsertion(rowID: RowID, values: [PluginCellValue]) {
        guard !insertedRowIDs.contains(rowID) else {
            insertedRowData[rowID] = values
            return
        }
        insertedRowData[rowID] = values
        appendChange(RowChange(rowID: rowID, type: .insert, cellChanges: []))
        insertedRowIDs.insert(rowID)
    }

    // MARK: - Mutate (cancelling pending edits)

    mutating func undoRowDeletion(rowID: RowID) -> Bool {
        guard deletedRowIDs.contains(rowID) else { return false }
        removeChange(rowID: rowID, type: .delete)
        deletedRowIDs.remove(rowID)
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
    mutating func reapplyRowDeletion(rowID: RowID, originalRow: [PluginCellValue]) {
        recordRowDeletion(rowID: rowID, originalRow: originalRow)
    }

    /// Re-apply a cell edit during undo replay (skips undo registration).
    /// `originalDBValue` is the cell's value in the unmodified database row.
    /// It must be preserved so that a later collapse compares correctly.
    mutating func reapplyCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        originalDBValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?
    ) {
        let cellChange = CellChange(
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: originalDBValue,
            newValue: newValue
        )

        if let insertIdx = changeIndex[RowChangeKey(rowID: rowID, type: .insert)] {
            updateInsertedCell(at: insertIdx, columnIndex: columnIndex,
                               columnName: columnName, newValue: newValue)
            return
        }

        let updateKey = RowChangeKey(rowID: rowID, type: .update)
        if let updateIdx = changeIndex[updateKey] {
            mergeUpdateCell(at: updateIdx, cellChange: cellChange)
        } else {
            let row = RowChange(
                rowID: rowID, type: .update,
                cellChanges: [cellChange], originalRow: originalRow
            )
            changes.append(row)
            changeIndex[updateKey] = changes.count - 1
            modifiedCells[rowID, default: []].insert(columnIndex)
        }
    }

    /// Replace an inserted row's cell value during undo replay (no undo).
    mutating func updateInsertedCellDirectly(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        newValue: PluginCellValue
    ) {
        guard let insertIdx = changeIndex[RowChangeKey(rowID: rowID, type: .insert)] else { return }
        updateInsertedCell(at: insertIdx, columnIndex: columnIndex, columnName: columnName, newValue: newValue)
    }

    /// Restore a cell's value during undo replay when an existing change matches.
    mutating func revertUpdateCell(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        previousValue: PluginCellValue
    ) {
        guard let updateIdx = changeIndex[RowChangeKey(rowID: rowID, type: .update)],
              let cellIdx = changes[updateIdx].cellChanges.firstIndex(where: { $0.columnIndex == columnIndex })
        else { return }

        let originalOldValue = changes[updateIdx].cellChanges[cellIdx].oldValue
        if previousValue == originalOldValue {
            changes[updateIdx].cellChanges.remove(at: cellIdx)
            removeModifiedCell(rowID: rowID, columnIndex: columnIndex)
            if changes[updateIdx].cellChanges.isEmpty {
                removeChangeAt(updateIdx)
            }
        } else {
            changes[updateIdx].cellChanges[cellIdx] = CellChange(
                columnIndex: columnIndex,
                columnName: columnName,
                oldValue: originalOldValue,
                newValue: previousValue
            )
        }
    }

    /// Insert a synthetic .insert RowChange for undo replay (e.g., after redoing a deletion's undo).
    mutating func reinsertRow(rowID: RowID, columns: [String], savedValues: [PluginCellValue]?) {
        insertedRowIDs.insert(rowID)
        let cellChanges = columns.enumerated().map { index, columnName in
            CellChange(
                columnIndex: index, columnName: columnName,
                oldValue: nil, newValue: savedValues?[safe: index] ?? nil
            )
        }
        appendChange(RowChange(rowID: rowID, type: .insert, cellChanges: cellChanges))
        if let savedValues {
            insertedRowData[rowID] = savedValues
        }
    }

    /// Insert a batch of rows (for undo replay of a batch deletion's undo).
    mutating func reinsertBatch(
        rowIDs: [RowID], rowValues: [[PluginCellValue]], columns: [String]
    ) {
        for (rowID, values) in zip(rowIDs, rowValues) {
            let cellChanges = values.enumerated().map { colIndex, value in
                CellChange(
                    columnIndex: colIndex,
                    columnName: columns[safe: colIndex] ?? "",
                    oldValue: nil, newValue: value
                )
            }
            appendChange(RowChange(rowID: rowID, type: .insert, cellChanges: cellChanges))
            insertedRowIDs.insert(rowID)
            insertedRowData[rowID] = values
        }
    }

    /// Save inserted-row values for a redo replay closure that may need them.
    func savedInsertedValues(forRow rowID: RowID) -> [PluginCellValue]? {
        insertedRowData[rowID]
    }

    /// Restore inserted-row values when undo restores a row.
    mutating func restoreInsertedValues(forRow rowID: RowID, values: [PluginCellValue]) {
        insertedRowData[rowID] = values
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
    }

    mutating func restore(from snapshot: TabChangeSnapshot) {
        changes = snapshot.changes
        deletedRowIDs = snapshot.deletedRowIDs
        insertedRowIDs = snapshot.insertedRowIDs
        modifiedCells = snapshot.modifiedCells
        insertedRowData = snapshot.insertedRowData
        nextSequence = (changes.map(\.sequence).max() ?? -1) + 1
        rebuildChangeIndex()
    }

    func snapshot(primaryKeyColumns: [String], columns: [String]) -> TabChangeSnapshot {
        var snap = TabChangeSnapshot()
        snap.changes = changes
        snap.deletedRowIDs = deletedRowIDs
        snap.insertedRowIDs = insertedRowIDs
        snap.modifiedCells = modifiedCells
        snap.insertedRowData = insertedRowData
        snap.primaryKeyColumns = primaryKeyColumns
        snap.columns = columns
        return snap
    }

    // MARK: - Internals

    private mutating func appendChange(_ change: RowChange) {
        var stamped = change
        stamped.sequence = nextSequence
        nextSequence += 1
        changes.append(stamped)
        changeIndex[RowChangeKey(rowID: stamped.rowID, type: stamped.type)] = changes.count - 1
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

    private mutating func rebuildChangeIndex() {
        changeIndex.removeAll(keepingCapacity: true)
        for (index, change) in changes.enumerated() {
            changeIndex[RowChangeKey(rowID: change.rowID, type: change.type)] = index
        }
    }

    private mutating func removeModifiedCell(rowID: RowID, columnIndex: Int) {
        modifiedCells[rowID]?.remove(columnIndex)
        if modifiedCells[rowID]?.isEmpty == true {
            modifiedCells.removeValue(forKey: rowID)
        }
    }

    private mutating func updateInsertedCell(
        at insertIdx: Int, columnIndex: Int, columnName: String, newValue: PluginCellValue
    ) {
        let rowID = changes[insertIdx].rowID
        if var stored = insertedRowData[rowID], columnIndex < stored.count {
            stored[columnIndex] = newValue
            insertedRowData[rowID] = stored
        }

        let replacement = CellChange(
            columnIndex: columnIndex, columnName: columnName,
            oldValue: nil, newValue: newValue
        )
        if let cellIdx = changes[insertIdx].cellChanges.firstIndex(where: { $0.columnIndex == columnIndex }) {
            changes[insertIdx].cellChanges[cellIdx] = replacement
        } else {
            changes[insertIdx].cellChanges.append(replacement)
        }
    }

    private mutating func mergeUpdateCell(at updateIdx: Int, cellChange: CellChange) {
        let rowID = changes[updateIdx].rowID
        guard let cellIdx = changes[updateIdx].cellChanges.firstIndex(where: {
            $0.columnIndex == cellChange.columnIndex
        }) else {
            changes[updateIdx].cellChanges.append(cellChange)
            modifiedCells[rowID, default: []].insert(cellChange.columnIndex)
            return
        }

        let originalOldValue = changes[updateIdx].cellChanges[cellIdx].oldValue
        changes[updateIdx].cellChanges[cellIdx] = CellChange(
            columnIndex: cellChange.columnIndex,
            columnName: cellChange.columnName,
            oldValue: originalOldValue,
            newValue: cellChange.newValue
        )

        guard originalOldValue == cellChange.newValue else { return }
        changes[updateIdx].cellChanges.remove(at: cellIdx)
        removeModifiedCell(rowID: rowID, columnIndex: cellChange.columnIndex)
        if changes[updateIdx].cellChanges.isEmpty {
            removeChangeAt(updateIdx)
        }
    }

    @discardableResult
    private mutating func rollbackCellIfMatchesOriginal(
        rowID: RowID, columnIndex: Int, restoredValue: PluginCellValue
    ) -> Bool {
        let updateKey = RowChangeKey(rowID: rowID, type: .update)
        guard let updateIdx = changeIndex[updateKey],
              let cellIdx = changes[updateIdx].cellChanges.firstIndex(where: { $0.columnIndex == columnIndex }),
              changes[updateIdx].cellChanges[cellIdx].oldValue == restoredValue else {
            return false
        }
        changes[updateIdx].cellChanges.remove(at: cellIdx)
        removeModifiedCell(rowID: rowID, columnIndex: columnIndex)
        if changes[updateIdx].cellChanges.isEmpty {
            removeChangeAt(updateIdx)
        }
        return true
    }
}
