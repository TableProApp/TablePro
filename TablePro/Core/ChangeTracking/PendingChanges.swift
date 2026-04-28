//
//  PendingChanges.swift
//  TablePro
//
//  Value type holding all uncommitted edits to a result set.
//  Owns the consistency invariants between `changes`, `changeIndex`,
//  `deletedRowIndices`, `insertedRowIndices`, `modifiedCells`, and
//  `insertedRowData`. Callers mutate through methods that maintain
//  the cross-collection state.
//

import Foundation

struct PendingChanges: Equatable {
    private(set) var changes: [RowChange] = []
    private(set) var deletedRowIndices: Set<Int> = []
    private(set) var insertedRowIndices: Set<Int> = []
    private(set) var modifiedCells: [Int: Set<Int>] = [:]
    private(set) var insertedRowData: [Int: [String?]] = [:]
    private(set) var changedRowIndices: Set<Int> = []

    private var changeIndex: [RowChangeKey: Int] = [:]

    var isEmpty: Bool { changes.isEmpty }
    var hasChanges: Bool { !isEmpty }

    // MARK: - Read

    func isRowDeleted(_ rowIndex: Int) -> Bool {
        deletedRowIndices.contains(rowIndex)
    }

    func isRowInserted(_ rowIndex: Int) -> Bool {
        insertedRowIndices.contains(rowIndex)
    }

    func isCellModified(rowIndex: Int, columnIndex: Int) -> Bool {
        modifiedCells[rowIndex]?.contains(columnIndex) == true
    }

    func modifiedColumns(forRow rowIndex: Int) -> Set<Int> {
        modifiedCells[rowIndex] ?? []
    }

    func change(forRow rowIndex: Int, type: ChangeType) -> RowChange? {
        guard let idx = changeIndex[RowChangeKey(rowIndex: rowIndex, type: type)] else { return nil }
        return changes[idx]
    }

    // MARK: - Mutate (recording user edits)

    /// Whether the recorded edit is a no-op (oldValue == newValue with no prior modification).
    /// Returns the result so the caller can decide whether to register undo.
    @discardableResult
    mutating func recordCellChange(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: String?,
        newValue: String?,
        originalRow: [String?]? = nil
    ) -> Bool {
        if oldValue == newValue {
            return rollbackCellIfMatchesOriginal(
                rowIndex: rowIndex, columnIndex: columnIndex, restoredValue: newValue
            )
        }

        let cellChange = CellChange(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue
        )

        if let insertIdx = changeIndex[RowChangeKey(rowIndex: rowIndex, type: .insert)] {
            updateInsertedCell(at: insertIdx, columnIndex: columnIndex,
                               columnName: columnName, newValue: newValue)
            changedRowIndices.insert(rowIndex)
            return true
        }

        let updateKey = RowChangeKey(rowIndex: rowIndex, type: .update)
        if let updateIdx = changeIndex[updateKey] {
            mergeUpdateCell(at: updateIdx, cellChange: cellChange)
        } else {
            let row = RowChange(
                rowIndex: rowIndex, type: .update,
                cellChanges: [cellChange], originalRow: originalRow
            )
            changes.append(row)
            changeIndex[updateKey] = changes.count - 1
            modifiedCells[rowIndex, default: []].insert(columnIndex)
        }
        changedRowIndices.insert(rowIndex)
        return true
    }

    mutating func recordRowDeletion(rowIndex: Int, originalRow: [String?]) {
        guard !deletedRowIndices.contains(rowIndex) else { return }
        removeChange(rowIndex: rowIndex, type: .update)
        modifiedCells.removeValue(forKey: rowIndex)
        appendChange(RowChange(rowIndex: rowIndex, type: .delete, originalRow: originalRow))
        deletedRowIndices.insert(rowIndex)
        changedRowIndices.insert(rowIndex)
    }

    mutating func recordRowInsertion(rowIndex: Int, values: [String?]) {
        guard !insertedRowIndices.contains(rowIndex) else {
            insertedRowData[rowIndex] = values
            return
        }
        insertedRowData[rowIndex] = values
        appendChange(RowChange(rowIndex: rowIndex, type: .insert, cellChanges: []))
        insertedRowIndices.insert(rowIndex)
        changedRowIndices.insert(rowIndex)
    }

    // MARK: - Mutate (cancelling pending edits)

    mutating func undoRowDeletion(rowIndex: Int) -> Bool {
        guard deletedRowIndices.contains(rowIndex) else { return false }
        removeChange(rowIndex: rowIndex, type: .delete)
        deletedRowIndices.remove(rowIndex)
        changedRowIndices.insert(rowIndex)
        return true
    }

    mutating func undoRowInsertion(rowIndex: Int) -> Bool {
        guard insertedRowIndices.contains(rowIndex) else { return false }

        removeChange(rowIndex: rowIndex, type: .insert)
        insertedRowIndices.remove(rowIndex)
        insertedRowData.removeValue(forKey: rowIndex)

        shiftRowIndicesDown(at: rowIndex)
        changedRowIndices.insert(rowIndex)
        return true
    }

    /// Undo a batch of inserted rows. Returns the saved values for each row in the same order.
    mutating func undoBatchRowInsertion(rowIndices: [Int], columnCount: Int) -> [[String?]] {
        let validRows = rowIndices.filter { insertedRowIndices.contains($0) }

        var rowValues: [[String?]] = []
        for rowIndex in validRows {
            if let idx = changeIndex[RowChangeKey(rowIndex: rowIndex, type: .insert)] {
                let values = changes[idx].cellChanges
                    .sorted { $0.columnIndex < $1.columnIndex }
                    .map { $0.newValue }
                rowValues.append(values)
            } else {
                rowValues.append(Array(repeating: nil, count: columnCount))
            }
        }

        for rowIndex in validRows {
            removeChange(rowIndex: rowIndex, type: .insert)
            insertedRowIndices.remove(rowIndex)
            insertedRowData.removeValue(forKey: rowIndex)
            changedRowIndices.insert(rowIndex)
        }

        let sortedRemoved = validRows.sorted()

        var newInserted = Set<Int>()
        for idx in insertedRowIndices {
            newInserted.insert(idx - Self.countLessThan(idx, in: sortedRemoved))
        }
        insertedRowIndices = newInserted

        for i in 0..<changes.count {
            let rowIndex = changes[i].rowIndex
            changes[i].rowIndex = rowIndex - Self.countLessThan(rowIndex, in: sortedRemoved)
        }

        rebuildChangeIndex()
        return rowValues
    }

    // MARK: - Replay (driven by NSUndoManager invocation)

    /// Re-apply a deletion during undo replay (skips undo registration).
    mutating func reapplyRowDeletion(rowIndex: Int, originalRow: [String?]) {
        guard !deletedRowIndices.contains(rowIndex) else { return }
        removeChange(rowIndex: rowIndex, type: .update)
        modifiedCells.removeValue(forKey: rowIndex)
        appendChange(RowChange(rowIndex: rowIndex, type: .delete, originalRow: originalRow))
        deletedRowIndices.insert(rowIndex)
        changedRowIndices.insert(rowIndex)
    }

    /// Re-apply a cell edit during undo replay (skips undo registration).
    /// `originalDBValue` is the cell's value in the unmodified database row.
    /// It must be preserved so that a later collapse compares correctly.
    mutating func reapplyCellChange(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        originalDBValue: String?,
        newValue: String?,
        originalRow: [String?]?
    ) {
        let cellChange = CellChange(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: originalDBValue,
            newValue: newValue
        )

        if let insertIdx = changeIndex[RowChangeKey(rowIndex: rowIndex, type: .insert)] {
            updateInsertedCell(at: insertIdx, columnIndex: columnIndex,
                               columnName: columnName, newValue: newValue)
            changedRowIndices.insert(rowIndex)
            return
        }

        let updateKey = RowChangeKey(rowIndex: rowIndex, type: .update)
        if let updateIdx = changeIndex[updateKey] {
            mergeUpdateCell(at: updateIdx, cellChange: cellChange)
        } else {
            let row = RowChange(
                rowIndex: rowIndex, type: .update,
                cellChanges: [cellChange], originalRow: originalRow
            )
            changes.append(row)
            changeIndex[updateKey] = changes.count - 1
            modifiedCells[rowIndex, default: []].insert(columnIndex)
        }
        changedRowIndices.insert(rowIndex)
    }

    /// Replace an inserted row's cell value during undo replay (no shift, no undo).
    mutating func updateInsertedCellDirectly(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        newValue: String?
    ) {
        guard let insertIdx = changeIndex[RowChangeKey(rowIndex: rowIndex, type: .insert)] else { return }
        updateInsertedCell(at: insertIdx, columnIndex: columnIndex, columnName: columnName, newValue: newValue)
        changedRowIndices.insert(rowIndex)
    }

    /// Restore a cell's value during undo replay when an existing change matches.
    mutating func revertUpdateCell(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        previousValue: String?
    ) {
        guard let updateIdx = changeIndex[RowChangeKey(rowIndex: rowIndex, type: .update)],
              let cellIdx = changes[updateIdx].cellChanges.firstIndex(where: { $0.columnIndex == columnIndex })
        else { return }

        let originalOldValue = changes[updateIdx].cellChanges[cellIdx].oldValue
        if previousValue == originalOldValue {
            changes[updateIdx].cellChanges.remove(at: cellIdx)
            modifiedCells[rowIndex]?.remove(columnIndex)
            if modifiedCells[rowIndex]?.isEmpty == true {
                modifiedCells.removeValue(forKey: rowIndex)
            }
            if changes[updateIdx].cellChanges.isEmpty {
                removeChangeAt(updateIdx)
            }
        } else {
            changes[updateIdx].cellChanges[cellIdx] = CellChange(
                rowIndex: rowIndex,
                columnIndex: columnIndex,
                columnName: columnName,
                oldValue: originalOldValue,
                newValue: previousValue
            )
        }
        changedRowIndices.insert(rowIndex)
    }

    /// Insert a synthetic .insert RowChange for undo replay (e.g., after redoing a deletion's undo).
    mutating func reinsertRow(rowIndex: Int, columns: [String], savedValues: [String?]?) {
        shiftRowIndicesUp(from: rowIndex)
        insertedRowIndices.insert(rowIndex)
        let cellChanges = columns.enumerated().map { index, columnName in
            CellChange(
                rowIndex: rowIndex, columnIndex: index, columnName: columnName,
                oldValue: nil, newValue: savedValues?[safe: index] ?? nil
            )
        }
        appendChange(RowChange(rowIndex: rowIndex, type: .insert, cellChanges: cellChanges))
        if let savedValues {
            insertedRowData[rowIndex] = savedValues
        }
        changedRowIndices.insert(rowIndex)
    }

    /// Insert a batch of rows (for undo replay of a batch deletion's undo).
    mutating func reinsertBatch(
        rowIndices: [Int], rowValues: [[String?]], columns: [String]
    ) {
        for rowIndex in rowIndices.sorted() {
            shiftRowIndicesUp(from: rowIndex)
        }
        for (index, rowIndex) in rowIndices.enumerated().reversed() {
            guard index < rowValues.count else { continue }
            let values = rowValues[index]
            let cellChanges = values.enumerated().map { colIndex, value in
                CellChange(
                    rowIndex: rowIndex, columnIndex: colIndex,
                    columnName: columns[safe: colIndex] ?? "",
                    oldValue: nil, newValue: value
                )
            }
            changes.append(RowChange(rowIndex: rowIndex, type: .insert, cellChanges: cellChanges))
            insertedRowIndices.insert(rowIndex)
            insertedRowData[rowIndex] = values
            changedRowIndices.insert(rowIndex)
        }
        rebuildChangeIndex()
    }

    /// Save inserted-row values for a redo replay closure that may need them.
    func savedInsertedValues(forRow rowIndex: Int) -> [String?]? {
        insertedRowData[rowIndex]
    }

    /// Restore inserted-row values when undo restores a row.
    mutating func restoreInsertedValues(forRow rowIndex: Int, values: [String?]) {
        insertedRowData[rowIndex] = values
    }

    // MARK: - Reset / persistence

    mutating func clear() {
        changes.removeAll()
        changeIndex.removeAll()
        deletedRowIndices.removeAll()
        insertedRowIndices.removeAll()
        modifiedCells.removeAll()
        insertedRowData.removeAll()
        changedRowIndices.removeAll()
    }

    mutating func consumeChangedRowIndices() -> Set<Int> {
        let indices = changedRowIndices
        changedRowIndices.removeAll()
        return indices
    }

    /// Replace internal state from a serialized snapshot.
    mutating func restore(from snapshot: TabChangeSnapshot) {
        changes = snapshot.changes
        deletedRowIndices = snapshot.deletedRowIndices
        insertedRowIndices = snapshot.insertedRowIndices
        modifiedCells = snapshot.modifiedCells
        insertedRowData = snapshot.insertedRowData
        changedRowIndices = []
        rebuildChangeIndex()
    }

    func snapshot(primaryKeyColumns: [String], columns: [String]) -> TabChangeSnapshot {
        var snap = TabChangeSnapshot()
        snap.changes = changes
        snap.deletedRowIndices = deletedRowIndices
        snap.insertedRowIndices = insertedRowIndices
        snap.modifiedCells = modifiedCells
        snap.insertedRowData = insertedRowData
        snap.primaryKeyColumns = primaryKeyColumns
        snap.columns = columns
        return snap
    }

    // MARK: - Internals

    private mutating func appendChange(_ change: RowChange) {
        changes.append(change)
        changeIndex[RowChangeKey(rowIndex: change.rowIndex, type: change.type)] = changes.count - 1
    }

    @discardableResult
    private mutating func removeChange(rowIndex: Int, type: ChangeType) -> Bool {
        let key = RowChangeKey(rowIndex: rowIndex, type: type)
        guard let arrayIndex = changeIndex[key] else { return false }
        removeChangeAt(arrayIndex)
        return true
    }

    private mutating func removeChangeAt(_ arrayIndex: Int) {
        let removed = changes[arrayIndex]
        changeIndex.removeValue(forKey: RowChangeKey(rowIndex: removed.rowIndex, type: removed.type))
        changes.remove(at: arrayIndex)

        for (key, idx) in changeIndex where idx > arrayIndex {
            changeIndex[key] = idx - 1
        }
    }

    private mutating func rebuildChangeIndex() {
        changeIndex.removeAll(keepingCapacity: true)
        for (index, change) in changes.enumerated() {
            changeIndex[RowChangeKey(rowIndex: change.rowIndex, type: change.type)] = index
        }
    }

    private mutating func updateInsertedCell(
        at insertIdx: Int, columnIndex: Int, columnName: String, newValue: String?
    ) {
        let rowIndex = changes[insertIdx].rowIndex
        if var stored = insertedRowData[rowIndex], columnIndex < stored.count {
            stored[columnIndex] = newValue
            insertedRowData[rowIndex] = stored
        }

        let replacement = CellChange(
            rowIndex: rowIndex, columnIndex: columnIndex, columnName: columnName,
            oldValue: nil, newValue: newValue
        )
        if let cellIdx = changes[insertIdx].cellChanges.firstIndex(where: { $0.columnIndex == columnIndex }) {
            changes[insertIdx].cellChanges[cellIdx] = replacement
        } else {
            changes[insertIdx].cellChanges.append(replacement)
        }
    }

    private mutating func mergeUpdateCell(at updateIdx: Int, cellChange: CellChange) {
        let rowIndex = changes[updateIdx].rowIndex
        if let cellIdx = changes[updateIdx].cellChanges.firstIndex(where: {
            $0.columnIndex == cellChange.columnIndex
        }) {
            let originalOldValue = changes[updateIdx].cellChanges[cellIdx].oldValue
            let merged = CellChange(
                rowIndex: rowIndex,
                columnIndex: cellChange.columnIndex,
                columnName: cellChange.columnName,
                oldValue: originalOldValue,
                newValue: cellChange.newValue
            )
            changes[updateIdx].cellChanges[cellIdx] = merged

            if originalOldValue == cellChange.newValue {
                changes[updateIdx].cellChanges.remove(at: cellIdx)
                modifiedCells[rowIndex]?.remove(cellChange.columnIndex)
                if modifiedCells[rowIndex]?.isEmpty == true {
                    modifiedCells.removeValue(forKey: rowIndex)
                }
                if changes[updateIdx].cellChanges.isEmpty {
                    removeChangeAt(updateIdx)
                }
            }
        } else {
            changes[updateIdx].cellChanges.append(cellChange)
            modifiedCells[rowIndex, default: []].insert(cellChange.columnIndex)
        }
    }

    @discardableResult
    private mutating func rollbackCellIfMatchesOriginal(
        rowIndex: Int, columnIndex: Int, restoredValue: String?
    ) -> Bool {
        let updateKey = RowChangeKey(rowIndex: rowIndex, type: .update)
        guard let updateIdx = changeIndex[updateKey],
              let cellIdx = changes[updateIdx].cellChanges.firstIndex(where: { $0.columnIndex == columnIndex }),
              changes[updateIdx].cellChanges[cellIdx].oldValue == restoredValue else {
            return false
        }
        changes[updateIdx].cellChanges.remove(at: cellIdx)
        modifiedCells[rowIndex]?.remove(columnIndex)
        if modifiedCells[rowIndex]?.isEmpty == true {
            modifiedCells.removeValue(forKey: rowIndex)
        }
        if changes[updateIdx].cellChanges.isEmpty {
            removeChangeAt(updateIdx)
        }
        changedRowIndices.insert(rowIndex)
        return true
    }

    private mutating func shiftRowIndicesUp(from insertionPoint: Int) {
        for i in 0..<changes.count where changes[i].rowIndex >= insertionPoint {
            changes[i].rowIndex += 1
        }
        insertedRowIndices = Set(insertedRowIndices.map { $0 >= insertionPoint ? $0 + 1 : $0 })
        deletedRowIndices = Set(deletedRowIndices.map { $0 >= insertionPoint ? $0 + 1 : $0 })

        var newInsertedRowData: [Int: [String?]] = [:]
        for (key, value) in insertedRowData {
            newInsertedRowData[key >= insertionPoint ? key + 1 : key] = value
        }
        insertedRowData = newInsertedRowData

        var newModifiedCells: [Int: Set<Int>] = [:]
        for (key, value) in modifiedCells {
            newModifiedCells[key >= insertionPoint ? key + 1 : key] = value
        }
        modifiedCells = newModifiedCells

        changedRowIndices = Set(changedRowIndices.map { $0 >= insertionPoint ? $0 + 1 : $0 })
        rebuildChangeIndex()
    }

    private mutating func shiftRowIndicesDown(at removedRow: Int) {
        for i in 0..<changes.count where changes[i].rowIndex > removedRow {
            changes[i].rowIndex -= 1
        }
        insertedRowIndices = Set(insertedRowIndices.map { $0 > removedRow ? $0 - 1 : $0 })

        var newInsertedRowData: [Int: [String?]] = [:]
        for (key, value) in insertedRowData {
            newInsertedRowData[key > removedRow ? key - 1 : key] = value
        }
        insertedRowData = newInsertedRowData

        var newModifiedCells: [Int: Set<Int>] = [:]
        for (key, value) in modifiedCells where key != removedRow {
            newModifiedCells[key > removedRow ? key - 1 : key] = value
        }
        modifiedCells = newModifiedCells
        rebuildChangeIndex()
    }

    /// Binary search: count of elements strictly less than `target` in a sorted array.
    private static func countLessThan(_ target: Int, in sorted: [Int]) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}
