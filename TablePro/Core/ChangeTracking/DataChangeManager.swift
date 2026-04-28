//
//  DataChangeManager.swift
//  TablePro
//
//  Manager for tracking data changes with O(1) lookups.
//  Delegates SQL generation to SQLStatementGenerator.
//  Uses Apple's UndoManager (NSUndoManager) for undo/redo stack management.
//

import Foundation
import Observation
import os
import TableProPluginKit

struct UndoResult {
    let action: UndoAction
    let needsRowRemoval: Bool
    let needsRowRestore: Bool
    let restoreRow: [String?]?
}

/// Manager for tracking and applying data changes
/// @MainActor ensures thread-safe access - critical for avoiding EXC_BAD_ACCESS
/// when multiple queries complete simultaneously (e.g., rapid sorting over SSH tunnel)
@MainActor @Observable
final class DataChangeManager: ChangeManaging {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DataChangeManager")
    var changes: [RowChange] = []
    var rowChanges: [RowChange] { changes }
    var hasChanges: Bool = false
    var reloadVersion: Int = 0

    private(set) var changedRowIndices: Set<Int> = []

    var tableName: String = ""
    var primaryKeyColumns: [String] = []
    /// First PK column, for contexts that need a single column (paste, filters)
    var primaryKeyColumn: String? { primaryKeyColumns.first }
    var databaseType: DatabaseType = .mysql
    var pluginDriver: (any PluginDatabaseDriver)?

    private var _columnsStorage: [String] = []
    var columns: [String] {
        get { _columnsStorage }
        set { _columnsStorage = newValue.map { String($0) } }
    }

    // MARK: - Cached Lookups for O(1) Performance

    private var deletedRowIndices: Set<Int> = []
    private(set) var insertedRowIndices: Set<Int> = []
    private var modifiedCells: [Int: Set<Int>] = [:]
    private var insertedRowData: [Int: [String?]] = [:]

    /// (rowIndex, changeType) → index in `changes` array for O(1) lookup
    /// Replaces O(n) `firstIndex(where:)` scans in hot paths like `recordCellChange`
    private var changeIndex: [RowChangeKey: Int] = [:]

    /// Rebuild `changeIndex` from the `changes` array.
    /// Called only for complex operations (bulk shifts, restoreState, clearChanges).
    private func rebuildChangeIndex() {
        changeIndex.removeAll(keepingCapacity: true)
        for (index, change) in changes.enumerated() {
            changeIndex[RowChangeKey(rowIndex: change.rowIndex, type: change.type)] = index
        }
    }

    /// Remove a single change at a known array index and update changeIndex incrementally.
    /// O(n) for index adjustment but avoids full dictionary rebuild.
    private func removeChangeAt(_ arrayIndex: Int) {
        let removed = changes[arrayIndex]
        let removedKey = RowChangeKey(rowIndex: removed.rowIndex, type: removed.type)
        changeIndex.removeValue(forKey: removedKey)
        changes.remove(at: arrayIndex)

        for (key, idx) in changeIndex where idx > arrayIndex {
            changeIndex[key] = idx - 1
        }
    }

    @discardableResult
    private func removeChangeByKey(rowIndex: Int, type: ChangeType) -> Bool {
        let key = RowChangeKey(rowIndex: rowIndex, type: type)
        guard let arrayIndex = changeIndex[key] else { return false }
        removeChangeAt(arrayIndex)
        return true
    }

    /// Binary search: count of elements in a sorted array that are strictly less than `target`.
    /// Used for O(n log n) batch index shifting instead of O(n²) nested loops.
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

    var undoManagerProvider: (() -> UndoManager?)?
    var onUndoApplied: ((UndoResult) -> Void)?

    private var lastUndoResult: UndoResult?

    // MARK: - Undo/Redo Properties

    var canUndo: Bool { undoManagerProvider?()?.canUndo ?? false }
    var canRedo: Bool { undoManagerProvider?()?.canRedo ?? false }

    private func registerUndo(actionName: String, _ handler: @escaping (DataChangeManager) -> Void) {
        guard let undoManager = undoManagerProvider?() else { return }
        undoManager.registerUndo(withTarget: self, handler: handler)
        undoManager.setActionName(actionName)
    }

    // MARK: - Helper Methods

    func consumeChangedRowIndices() -> Set<Int> {
        let indices = changedRowIndices
        changedRowIndices.removeAll()
        return indices
    }

    // MARK: - Configuration

    func clearChanges() {
        changes.removeAll()
        changeIndex.removeAll()
        deletedRowIndices.removeAll()
        insertedRowIndices.removeAll()
        modifiedCells.removeAll()
        insertedRowData.removeAll()
        changedRowIndices.removeAll()
        hasChanges = false
        reloadVersion += 1
    }

    func clearChangesAndUndoHistory() {
        clearChanges()
        undoManagerProvider?()?.removeAllActions(withTarget: self)
    }

    func configureForTable(
        tableName: String,
        columns: [String],
        primaryKeyColumns: [String],
        databaseType: DatabaseType = .mysql,
        triggerReload: Bool = true
    ) {
        self.tableName = tableName
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.databaseType = databaseType

        changeIndex.removeAll()
        deletedRowIndices.removeAll()
        insertedRowIndices.removeAll()
        modifiedCells.removeAll()
        insertedRowData.removeAll()
        changedRowIndices.removeAll()
        undoManagerProvider?()?.removeAllActions(withTarget: self)

        changes.removeAll()
        hasChanges = false
        if triggerReload {
            reloadVersion += 1
        }
    }

    // MARK: - Change Tracking

    func recordCellChange(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: String?,
        newValue: String?,
        originalRow: [String?]? = nil
    ) {
        if oldValue == newValue {
            let updateKey = RowChangeKey(rowIndex: rowIndex, type: .update)
            if let existingIndex = changeIndex[updateKey],
               let cellIndex = changes[existingIndex].cellChanges.firstIndex(where: { $0.columnIndex == columnIndex }) {
                let originalOldValue = changes[existingIndex].cellChanges[cellIndex].oldValue
                if originalOldValue == newValue {
                    changes[existingIndex].cellChanges.remove(at: cellIndex)
                    modifiedCells[rowIndex]?.remove(columnIndex)
                    if modifiedCells[rowIndex]?.isEmpty == true { modifiedCells.removeValue(forKey: rowIndex) }
                    if changes[existingIndex].cellChanges.isEmpty { removeChangeAt(existingIndex) }
                    changedRowIndices.insert(rowIndex)
                    hasChanges = !changes.isEmpty
                    reloadVersion += 1
                }
            }
            return
        }

        let cellChange = CellChange(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue
        )

        let insertKey = RowChangeKey(rowIndex: rowIndex, type: .insert)
        if let insertIndex = changeIndex[insertKey] {
            if var storedValues = insertedRowData[rowIndex] {
                if columnIndex < storedValues.count {
                    storedValues[columnIndex] = newValue
                    insertedRowData[rowIndex] = storedValues
                }
            }

            if let cellIndex = changes[insertIndex].cellChanges.firstIndex(where: {
                $0.columnIndex == columnIndex
            }) {
                changes[insertIndex].cellChanges[cellIndex] = CellChange(
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    columnName: columnName,
                    oldValue: nil,
                    newValue: newValue
                )
            } else {
                changes[insertIndex].cellChanges.append(CellChange(
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    columnName: columnName,
                    oldValue: nil,
                    newValue: newValue
                ))
            }
            registerUndo(actionName: String(localized: "Edit Cell")) { target in
                target.applyDataUndo(.cellEdit(
                    rowIndex: rowIndex, columnIndex: columnIndex, columnName: columnName,
                    previousValue: oldValue, newValue: newValue, originalRow: nil
                ))
            }
            changedRowIndices.insert(rowIndex)
            hasChanges = !changes.isEmpty
            reloadVersion += 1
            return
        }

        let updateKey = RowChangeKey(rowIndex: rowIndex, type: .update)
        if let existingIndex = changeIndex[updateKey] {
            if let cellIndex = changes[existingIndex].cellChanges.firstIndex(where: {
                $0.columnIndex == columnIndex
            }) {
                let originalOldValue = changes[existingIndex].cellChanges[cellIndex].oldValue
                changes[existingIndex].cellChanges[cellIndex] = CellChange(
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    columnName: columnName,
                    oldValue: originalOldValue,
                    newValue: newValue
                )

                if originalOldValue == newValue {
                    changes[existingIndex].cellChanges.remove(at: cellIndex)
                    modifiedCells[rowIndex]?.remove(columnIndex)
                    if modifiedCells[rowIndex]?.isEmpty == true {
                        modifiedCells.removeValue(forKey: rowIndex)
                    }
                    if changes[existingIndex].cellChanges.isEmpty {
                        removeChangeAt(existingIndex)
                    }
                }
            } else {
                changes[existingIndex].cellChanges.append(cellChange)
                modifiedCells[rowIndex, default: []].insert(columnIndex)
            }
            changedRowIndices.insert(rowIndex)
        } else {
            let rowChange = RowChange(
                rowIndex: rowIndex,
                type: .update,
                cellChanges: [cellChange],
                originalRow: originalRow
            )
            changes.append(rowChange)
            changeIndex[updateKey] = changes.count - 1
            modifiedCells[rowIndex, default: []].insert(columnIndex)
            changedRowIndices.insert(rowIndex)
        }

        registerUndo(actionName: String(localized: "Edit Cell")) { target in
            target.applyDataUndo(.cellEdit(
                rowIndex: rowIndex, columnIndex: columnIndex, columnName: columnName,
                previousValue: oldValue, newValue: newValue, originalRow: originalRow
            ))
        }
        hasChanges = !changes.isEmpty
        reloadVersion += 1
    }

    func recordRowDeletion(rowIndex: Int, originalRow: [String?]) {
        removeChangeByKey(rowIndex: rowIndex, type: .update)
        modifiedCells.removeValue(forKey: rowIndex)

        let rowChange = RowChange(rowIndex: rowIndex, type: .delete, originalRow: originalRow)
        changes.append(rowChange)
        changeIndex[RowChangeKey(rowIndex: rowIndex, type: .delete)] = changes.count - 1
        deletedRowIndices.insert(rowIndex)
        changedRowIndices.insert(rowIndex)
        registerUndo(actionName: String(localized: "Delete Row")) { target in
            target.applyDataUndo(.rowDeletion(rowIndex: rowIndex, originalRow: originalRow))
        }
        hasChanges = true
        reloadVersion += 1
    }

    func recordBatchRowDeletion(rows: [(rowIndex: Int, originalRow: [String?])]) {
        guard rows.count > 1 else {
            if let row = rows.first {
                recordRowDeletion(rowIndex: row.rowIndex, originalRow: row.originalRow)
            }
            return
        }

        var batchData: [(rowIndex: Int, originalRow: [String?])] = []

        for (rowIndex, originalRow) in rows {
            removeChangeByKey(rowIndex: rowIndex, type: .update)
            modifiedCells.removeValue(forKey: rowIndex)

            let rowChange = RowChange(rowIndex: rowIndex, type: .delete, originalRow: originalRow)
            changes.append(rowChange)
            changeIndex[RowChangeKey(rowIndex: rowIndex, type: .delete)] = changes.count - 1
            deletedRowIndices.insert(rowIndex)
            changedRowIndices.insert(rowIndex)
            batchData.append((rowIndex: rowIndex, originalRow: originalRow))
        }
        registerUndo(actionName: String(localized: "Delete Rows")) { target in
            target.applyDataUndo(.batchRowDeletion(rows: batchData))
        }
        hasChanges = true
        reloadVersion += 1
    }

    func recordRowInsertion(rowIndex: Int, values: [String?]) {
        insertedRowData[rowIndex] = values
        let rowChange = RowChange(rowIndex: rowIndex, type: .insert, cellChanges: [])
        changes.append(rowChange)
        changeIndex[RowChangeKey(rowIndex: rowIndex, type: .insert)] = changes.count - 1
        insertedRowIndices.insert(rowIndex)
        changedRowIndices.insert(rowIndex)
        registerUndo(actionName: String(localized: "Insert Row")) { target in
            target.applyDataUndo(.rowInsertion(rowIndex: rowIndex))
        }
        hasChanges = true
        reloadVersion += 1
    }

    // MARK: - Undo Operations

    func undoRowDeletion(rowIndex: Int) {
        guard deletedRowIndices.contains(rowIndex) else { return }
        removeChangeByKey(rowIndex: rowIndex, type: .delete)
        deletedRowIndices.remove(rowIndex)
        hasChanges = !changes.isEmpty
        reloadVersion += 1
    }

    func undoRowInsertion(rowIndex: Int) {
        guard insertedRowIndices.contains(rowIndex) else { return }

        removeChangeByKey(rowIndex: rowIndex, type: .insert)
        insertedRowIndices.remove(rowIndex)
        insertedRowData.removeValue(forKey: rowIndex)

        var shiftedInsertedIndices = Set<Int>()
        for idx in insertedRowIndices {
            shiftedInsertedIndices.insert(idx > rowIndex ? idx - 1 : idx)
        }
        insertedRowIndices = shiftedInsertedIndices

        for i in 0..<changes.count {
            if changes[i].rowIndex > rowIndex {
                changes[i].rowIndex -= 1
            }
        }

        var newInsertedRowData: [Int: [String?]] = [:]
        for (key, value) in insertedRowData {
            if key > rowIndex {
                newInsertedRowData[key - 1] = value
            } else {
                newInsertedRowData[key] = value
            }
        }
        insertedRowData = newInsertedRowData

        var newModifiedCells: [Int: Set<Int>] = [:]
        for (key, value) in modifiedCells {
            if key > rowIndex {
                newModifiedCells[key - 1] = value
            } else if key < rowIndex {
                newModifiedCells[key] = value
            }
        }
        modifiedCells = newModifiedCells

        rebuildChangeIndex()
        hasChanges = !changes.isEmpty
    }

    private func shiftRowIndicesUp(from insertionPoint: Int) {
        for i in 0..<changes.count {
            if changes[i].rowIndex >= insertionPoint {
                changes[i].rowIndex += 1
            }
        }

        var shiftedInserted = Set<Int>()
        for idx in insertedRowIndices {
            shiftedInserted.insert(idx >= insertionPoint ? idx + 1 : idx)
        }
        insertedRowIndices = shiftedInserted

        var shiftedDeleted = Set<Int>()
        for idx in deletedRowIndices {
            shiftedDeleted.insert(idx >= insertionPoint ? idx + 1 : idx)
        }
        deletedRowIndices = shiftedDeleted

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

        var newChangedRows = Set<Int>()
        for idx in changedRowIndices {
            newChangedRows.insert(idx >= insertionPoint ? idx + 1 : idx)
        }
        changedRowIndices = newChangedRows

        rebuildChangeIndex()
    }

    func undoBatchRowInsertion(rowIndices: [Int]) {
        guard !rowIndices.isEmpty else { return }

        let validRows = rowIndices.filter { insertedRowIndices.contains($0) }
        guard !validRows.isEmpty else { return }

        var rowValues: [[String?]] = []
        for rowIndex in validRows {
            let key = RowChangeKey(rowIndex: rowIndex, type: .insert)
            if let idx = changeIndex[key] {
                let values = changes[idx].cellChanges.sorted { $0.columnIndex < $1.columnIndex }
                    .map { $0.newValue }
                rowValues.append(values)
            } else {
                rowValues.append(Array(repeating: nil, count: columns.count))
            }
        }

        for rowIndex in validRows {
            removeChangeByKey(rowIndex: rowIndex, type: .insert)
            insertedRowIndices.remove(rowIndex)
            insertedRowData.removeValue(forKey: rowIndex)
        }

        registerUndo(actionName: String(localized: "Insert Rows")) { target in
            target.applyDataUndo(.batchRowInsertion(rowIndices: validRows, rowValues: rowValues))
        }

        let sortedDeleted = validRows.sorted()

        var newInserted = Set<Int>()
        for idx in insertedRowIndices {
            let shiftCount = Self.countLessThan(idx, in: sortedDeleted)
            newInserted.insert(idx - shiftCount)
        }
        insertedRowIndices = newInserted

        for i in 0..<changes.count {
            let rowIndex = changes[i].rowIndex
            let shiftCount = Self.countLessThan(rowIndex, in: sortedDeleted)
            changes[i].rowIndex = rowIndex - shiftCount
        }

        rebuildChangeIndex()
        hasChanges = !changes.isEmpty
    }

    // MARK: - Core Undo Application

    // swiftlint:disable:next function_body_length
    private func applyDataUndo(_ action: UndoAction) {
        switch action {
        case .cellEdit(let rowIndex, let columnIndex, let columnName, let previousValue, let newValue, let originalRow):
            registerUndo(actionName: String(localized: "Edit Cell")) { target in
                target.applyDataUndo(.cellEdit(
                    rowIndex: rowIndex, columnIndex: columnIndex, columnName: columnName,
                    previousValue: newValue, newValue: previousValue, originalRow: originalRow
                ))
            }

            let matchedIndex = changeIndex[RowChangeKey(rowIndex: rowIndex, type: .update)]
                ?? changeIndex[RowChangeKey(rowIndex: rowIndex, type: .insert)]
            if let changeIdx = matchedIndex {
                if let cellIndex = changes[changeIdx].cellChanges.firstIndex(where: {
                    $0.columnIndex == columnIndex
                }) {
                    if changes[changeIdx].type == .update {
                        let originalValue = changes[changeIdx].cellChanges[cellIndex].oldValue
                        if previousValue == originalValue {
                            changes[changeIdx].cellChanges.remove(at: cellIndex)
                            modifiedCells[rowIndex]?.remove(columnIndex)
                            if modifiedCells[rowIndex]?.isEmpty == true {
                                modifiedCells.removeValue(forKey: rowIndex)
                            }
                            if changes[changeIdx].cellChanges.isEmpty {
                                removeChangeAt(changeIdx)
                            }
                        } else {
                            let originalOldValue = changes[changeIdx].cellChanges[cellIndex].oldValue
                            changes[changeIdx].cellChanges[cellIndex] = CellChange(
                                rowIndex: rowIndex,
                                columnIndex: columnIndex,
                                columnName: columnName,
                                oldValue: originalOldValue,
                                newValue: previousValue
                            )
                        }
                    } else if changes[changeIdx].type == .insert {
                        changes[changeIdx].cellChanges[cellIndex] = CellChange(
                            rowIndex: rowIndex,
                            columnIndex: columnIndex,
                            columnName: columnName,
                            oldValue: nil,
                            newValue: previousValue
                        )
                        if var storedValues = insertedRowData[rowIndex],
                           columnIndex < storedValues.count {
                            storedValues[columnIndex] = previousValue
                            insertedRowData[rowIndex] = storedValues
                        }
                    }
                }
            } else {
                recordCellChangeForRedo(
                    rowIndex: rowIndex, columnIndex: columnIndex, columnName: columnName,
                    oldValue: newValue, newValue: previousValue, originalRow: originalRow
                )
            }
            changedRowIndices.insert(rowIndex)
            lastUndoResult = UndoResult(action: action, needsRowRemoval: false, needsRowRestore: false, restoreRow: nil)

        case .rowInsertion(let rowIndex):
            let savedValues = insertedRowData[rowIndex]
            registerUndo(actionName: String(localized: "Insert Row")) { [savedValues] target in
                if let savedValues {
                    target.insertedRowData[rowIndex] = savedValues
                }
                target.applyDataUndo(.rowInsertion(rowIndex: rowIndex))
            }

            if insertedRowIndices.contains(rowIndex) {
                undoRowInsertion(rowIndex: rowIndex)
                changedRowIndices.insert(rowIndex)
                lastUndoResult = UndoResult(
                    action: action, needsRowRemoval: true, needsRowRestore: false, restoreRow: nil
                )
            } else {
                shiftRowIndicesUp(from: rowIndex)
                insertedRowIndices.insert(rowIndex)
                let cellChanges = columns.enumerated().map { index, columnName in
                    CellChange(
                        rowIndex: rowIndex,
                        columnIndex: index,
                        columnName: columnName,
                        oldValue: nil,
                        newValue: savedValues?[safe: index] ?? nil
                    )
                }
                let rowChange = RowChange(rowIndex: rowIndex, type: .insert, cellChanges: cellChanges)
                changes.append(rowChange)
                changeIndex[RowChangeKey(rowIndex: rowIndex, type: .insert)] = changes.count - 1
                if let savedValues {
                    insertedRowData[rowIndex] = savedValues
                }
                changedRowIndices.insert(rowIndex)
                lastUndoResult = UndoResult(
                    action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: savedValues
                )
            }

        case .rowDeletion(let rowIndex, let originalRow):
            registerUndo(actionName: String(localized: "Delete Row")) { target in
                target.applyDataUndo(.rowDeletion(rowIndex: rowIndex, originalRow: originalRow))
            }

            if deletedRowIndices.contains(rowIndex) {
                undoRowDeletion(rowIndex: rowIndex)
                changedRowIndices.insert(rowIndex)
                lastUndoResult = UndoResult(
                    action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: originalRow
                )
            } else {
                redoRowDeletion(rowIndex: rowIndex, originalRow: originalRow)
                changedRowIndices.insert(rowIndex)
                lastUndoResult = UndoResult(
                    action: action, needsRowRemoval: true, needsRowRestore: false, restoreRow: nil
                )
            }

        case .batchRowDeletion(let rows):
            registerUndo(actionName: String(localized: "Delete Rows")) { target in
                target.applyDataUndo(.batchRowDeletion(rows: rows))
            }

            let isUndo = rows.contains { deletedRowIndices.contains($0.rowIndex) }
            if isUndo {
                for (rowIndex, _) in rows.reversed() {
                    undoRowDeletion(rowIndex: rowIndex)
                    changedRowIndices.insert(rowIndex)
                }
                lastUndoResult = UndoResult(
                    action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: nil
                )
            } else {
                for (rowIndex, originalRow) in rows {
                    redoRowDeletion(rowIndex: rowIndex, originalRow: originalRow)
                    changedRowIndices.insert(rowIndex)
                }
                lastUndoResult = UndoResult(
                    action: action, needsRowRemoval: true, needsRowRestore: false, restoreRow: nil
                )
            }

        case .batchRowInsertion(let rowIndices, let rowValues):
            registerUndo(actionName: String(localized: "Insert Rows")) { target in
                target.applyDataUndo(.batchRowInsertion(rowIndices: rowIndices, rowValues: rowValues))
            }

            let firstInserted = rowIndices.first.map { insertedRowIndices.contains($0) } ?? false
            if firstInserted {
                for rowIndex in rowIndices {
                    removeChangeByKey(rowIndex: rowIndex, type: .insert)
                    insertedRowIndices.remove(rowIndex)
                    insertedRowData.removeValue(forKey: rowIndex)
                    changedRowIndices.insert(rowIndex)
                }
                lastUndoResult = UndoResult(
                    action: action, needsRowRemoval: true, needsRowRestore: false, restoreRow: nil
                )
            } else {
                // Shift existing rows up for each insertion point (ascending order)
                for rowIndex in rowIndices.sorted() {
                    shiftRowIndicesUp(from: rowIndex)
                }

                for (index, rowIndex) in rowIndices.enumerated().reversed() {
                    guard index < rowValues.count else { continue }
                    let values = rowValues[index]

                    let cellChanges = values.enumerated().map { colIndex, value in
                        CellChange(
                            rowIndex: rowIndex,
                            columnIndex: colIndex,
                            columnName: columns[safe: colIndex] ?? "",
                            oldValue: nil,
                            newValue: value
                        )
                    }
                    let rowChange = RowChange(rowIndex: rowIndex, type: .insert, cellChanges: cellChanges)
                    changes.append(rowChange)
                    insertedRowIndices.insert(rowIndex)
                    insertedRowData[rowIndex] = values
                }

                rebuildChangeIndex()
                lastUndoResult = UndoResult(
                    action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: nil
                )
            }
        }

        hasChanges = !changes.isEmpty
        reloadVersion += 1

        if let result = lastUndoResult {
            onUndoApplied?(result)
        }
    }

    private func recordCellChangeForRedo(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: String?,
        newValue: String?,
        originalRow: [String?]?
    ) {
        let cellChange = CellChange(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue
        )

        let insertKey = RowChangeKey(rowIndex: rowIndex, type: .insert)
        if let insertIndex = changeIndex[insertKey] {
            if var storedValues = insertedRowData[rowIndex] {
                if columnIndex < storedValues.count {
                    storedValues[columnIndex] = newValue
                    insertedRowData[rowIndex] = storedValues
                }
            }
            if let cellIndex = changes[insertIndex].cellChanges.firstIndex(where: {
                $0.columnIndex == columnIndex
            }) {
                changes[insertIndex].cellChanges[cellIndex] = CellChange(
                    rowIndex: rowIndex, columnIndex: columnIndex, columnName: columnName,
                    oldValue: nil, newValue: newValue
                )
            } else {
                changes[insertIndex].cellChanges.append(CellChange(
                    rowIndex: rowIndex, columnIndex: columnIndex, columnName: columnName,
                    oldValue: nil, newValue: newValue
                ))
            }
            return
        }

        let updateKey = RowChangeKey(rowIndex: rowIndex, type: .update)
        if let existingIndex = changeIndex[updateKey] {
            if let cellIndex = changes[existingIndex].cellChanges.firstIndex(where: {
                $0.columnIndex == columnIndex
            }) {
                let originalOldValue = changes[existingIndex].cellChanges[cellIndex].oldValue
                changes[existingIndex].cellChanges[cellIndex] = CellChange(
                    rowIndex: rowIndex, columnIndex: columnIndex, columnName: columnName,
                    oldValue: originalOldValue, newValue: newValue
                )
            } else {
                changes[existingIndex].cellChanges.append(cellChange)
                modifiedCells[rowIndex, default: []].insert(columnIndex)
            }
        } else {
            let rowChange = RowChange(
                rowIndex: rowIndex, type: .update, cellChanges: [cellChange],
                originalRow: originalRow
            )
            changes.append(rowChange)
            changeIndex[updateKey] = changes.count - 1
            modifiedCells[rowIndex, default: []].insert(columnIndex)
        }
    }

    /// Re-apply a row deletion during redo without registering a duplicate undo
    private func redoRowDeletion(rowIndex: Int, originalRow: [String?]) {
        removeChangeByKey(rowIndex: rowIndex, type: .update)
        modifiedCells.removeValue(forKey: rowIndex)

        let rowChange = RowChange(rowIndex: rowIndex, type: .delete, originalRow: originalRow)
        changes.append(rowChange)
        changeIndex[RowChangeKey(rowIndex: rowIndex, type: .delete)] = changes.count - 1
        deletedRowIndices.insert(rowIndex)
        hasChanges = true
    }

    // MARK: - Undo/Redo Public API

    func undoLastChange() -> UndoResult? {
        guard let um = undoManagerProvider?(), um.canUndo else { return nil }
        lastUndoResult = nil
        um.undo()
        return lastUndoResult
    }

    func redoLastChange() -> UndoResult? {
        guard let um = undoManagerProvider?(), um.canRedo else { return nil }
        lastUndoResult = nil
        um.redo()
        return lastUndoResult
    }

    // MARK: - SQL Generation

    func generateSQL() throws -> [ParameterizedStatement] {
        try generateSQL(
            for: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    func generateSQL(
        for changes: [RowChange],
        insertedRowData: [Int: [String?]] = [:],
        deletedRowIndices: Set<Int> = [],
        insertedRowIndices: Set<Int> = []
    ) throws -> [ParameterizedStatement] {
        if let pluginDriver {
            let pluginChanges = changes.map { change -> PluginRowChange in
                PluginRowChange(
                    rowIndex: change.rowIndex,
                    type: {
                        switch change.type {
                        case .insert: return .insert
                        case .update: return .update
                        case .delete: return .delete
                        }
                    }(),
                    cellChanges: change.cellChanges.map {
                        ($0.columnIndex, $0.columnName, $0.oldValue, $0.newValue)
                    },
                    originalRow: change.originalRow
                )
            }
            if let statements = pluginDriver.generateStatements(
                table: tableName,
                columns: columns,
                changes: pluginChanges,
                insertedRowData: insertedRowData,
                deletedRowIndices: deletedRowIndices,
                insertedRowIndices: insertedRowIndices
            ) {
                return statements.map { ParameterizedStatement(sql: $0.statement, parameters: $0.parameters) }
            }
        }

        if PluginManager.shared.editorLanguage(for: databaseType) != .sql {
            throw DatabaseError.queryFailed(
                "Cannot generate statements for \(databaseType.rawValue) — plugin driver not initialized"
            )
        }

        let generator = SQLStatementGenerator(
            tableName: tableName,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: databaseType,
            dialect: PluginManager.shared.sqlDialect(for: databaseType),
            quoteIdentifier: pluginDriver?.quoteIdentifier
        )
        let statements = generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )

        let expectedUpdates = changes.count(where: { $0.type == .update })
        let actualUpdates = statements.count(where: { $0.sql.hasPrefix("UPDATE") })

        if expectedUpdates > 0 && actualUpdates < expectedUpdates {
            throw DatabaseError.queryFailed(
                "Cannot save UPDATE changes to table '\(tableName)'. " +
                    "Some rows could not be identified for updating. Please verify the table data."
            )
        }

        let deletableChanges = changes.filter { $0.type == .delete && deletedRowIndices.contains($0.rowIndex) }
        let deletableWithOriginalRow = deletableChanges.filter { $0.originalRow != nil }

        if !deletableChanges.isEmpty && deletableWithOriginalRow.isEmpty {
            throw DatabaseError.queryFailed(
                "Cannot save DELETE changes to table '\(tableName)'. " +
                    "Some rows could not be identified for deletion. Please verify the table data."
            )
        }

        return statements
    }

    // MARK: - Actions

    func getOriginalValues() -> [(rowIndex: Int, columnIndex: Int, value: String?)] {
        var originals: [(rowIndex: Int, columnIndex: Int, value: String?)] = []

        for change in changes {
            if change.type == .update {
                for cellChange in change.cellChanges {
                    originals.append((
                        rowIndex: change.rowIndex,
                        columnIndex: cellChange.columnIndex,
                        value: cellChange.oldValue
                    ))
                }
            }
        }

        return originals
    }

    func discardChanges() {
        changes.removeAll()
        changeIndex.removeAll()
        deletedRowIndices.removeAll()
        insertedRowIndices.removeAll()
        modifiedCells.removeAll()
        insertedRowData.removeAll()
        changedRowIndices.removeAll()
        hasChanges = false
        reloadVersion += 1
    }

    // MARK: - Per-Tab State Management

    func saveState() -> TabPendingChanges {
        var state = TabPendingChanges()
        state.changes = changes
        state.deletedRowIndices = deletedRowIndices
        state.insertedRowIndices = insertedRowIndices
        state.modifiedCells = modifiedCells
        state.insertedRowData = insertedRowData
        state.primaryKeyColumns = primaryKeyColumns
        state.columns = columns
        return state
    }

    func restoreState(from state: TabPendingChanges, tableName: String, databaseType: DatabaseType) {
        self.tableName = tableName
        self.columns = state.columns
        self.primaryKeyColumns = state.primaryKeyColumns
        self.databaseType = databaseType
        self.changes = state.changes
        self.deletedRowIndices = state.deletedRowIndices
        self.insertedRowIndices = state.insertedRowIndices
        self.modifiedCells = state.modifiedCells
        self.insertedRowData = state.insertedRowData
        self.hasChanges = !state.changes.isEmpty
        rebuildChangeIndex()
    }

    // MARK: - O(1) Lookups

    func isRowDeleted(_ rowIndex: Int) -> Bool {
        deletedRowIndices.contains(rowIndex)
    }

    func isRowInserted(_ rowIndex: Int) -> Bool {
        insertedRowIndices.contains(rowIndex)
    }

    func isCellModified(rowIndex: Int, columnIndex: Int) -> Bool {
        modifiedCells[rowIndex]?.contains(columnIndex) == true
    }

    func getModifiedColumnsForRow(_ rowIndex: Int) -> Set<Int> {
        modifiedCells[rowIndex] ?? []
    }
}
