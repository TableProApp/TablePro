//
//  DataChangeManager.swift
//  TablePro
//
//  Manager for tracking data changes with O(1) lookups.
//  Delegates SQL generation to SQLStatementGenerator.
//  Delegates undo/redo stack management to DataChangeUndoManager.
//

import Foundation
import Observation
import os
import TableProPluginKit

/// Manager for tracking and applying data changes
/// @MainActor ensures thread-safe access - critical for avoiding EXC_BAD_ACCESS
/// when multiple queries complete simultaneously (e.g., rapid sorting over SSH tunnel)
@MainActor @Observable
final class DataChangeManager {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DataChangeManager")
    var changes: [RowChange] = []
    var hasChanges: Bool = false
    var reloadVersion: Int = 0  // Incremented to trigger table reload

    // Track which rows changed since last reload for granular updates
    private(set) var changedRowIndices: Set<Int> = []

    var tableName: String = ""
    var primaryKeyColumn: String?
    var databaseType: DatabaseType = .mysql
    var pluginDriver: (any PluginDatabaseDriver)?

    // Simple storage with explicit deep copy to avoid memory corruption
    private var _columnsStorage: [String] = []
    var columns: [String] {
        get { _columnsStorage }
        set { _columnsStorage = newValue.map { String($0) } }
    }

    // MARK: - Cached Lookups for O(1) Performance

    /// Set of row indices that are marked for deletion - O(1) lookup
    private var deletedRowIndices: Set<Int> = []

    /// Set of row indices that are newly inserted - O(1) lookup
    private(set) var insertedRowIndices: Set<Int> = []

    /// Row index → modified column indices for O(1) per-cell lookup
    private var modifiedCells: [Int: Set<Int>] = [:]

    /// Lazy storage for inserted row values - avoids creating CellChange objects until needed
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

        // Decrement indices above the removed position
        for (key, idx) in changeIndex where idx > arrayIndex {
            changeIndex[key] = idx - 1
        }
    }

    /// Remove the change for a given (rowIndex, type) using O(1) index lookup.
    /// Returns true if a change was found and removed.
    @discardableResult
    private func removeChangeByKey(rowIndex: Int, type: ChangeType) -> Bool {
        let key = RowChangeKey(rowIndex: rowIndex, type: type)
        guard let arrayIndex = changeIndex[key] else { return false }
        removeChangeAt(arrayIndex)
        return true
    }

    /// Undo/redo manager
    private let undoManager = DataChangeUndoManager()

    /// Flag to prevent clearing redo stack during redo operations
    private var isRedoing = false

    // MARK: - Undo/Redo Properties

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    // MARK: - Helper Methods

    /// Consume and clear changed row indices (for granular table reloads)
    func consumeChangedRowIndices() -> Set<Int> {
        let indices = changedRowIndices
        changedRowIndices.removeAll()
        return indices
    }

    // MARK: - Configuration

    /// Clear all changes (called after successful save)
    func clearChanges() {
        changes.removeAll()
        changeIndex.removeAll()
        deletedRowIndices.removeAll()
        insertedRowIndices.removeAll()
        modifiedCells.removeAll()
        insertedRowData.removeAll()
        changedRowIndices.removeAll()
        undoManager.clearAll()
        hasChanges = false
        reloadVersion += 1
    }

    /// Atomically configure the manager for a new table
    func configureForTable(
        tableName: String,
        columns: [String],
        primaryKeyColumn: String?,
        databaseType: DatabaseType = .mysql,
        triggerReload: Bool = true
    ) {
        self.tableName = tableName
        self.columns = columns
        self.primaryKeyColumn = primaryKeyColumn
        self.databaseType = databaseType

        changeIndex.removeAll()
        deletedRowIndices.removeAll()
        insertedRowIndices.removeAll()
        modifiedCells.removeAll()
        insertedRowData.removeAll()
        changedRowIndices.removeAll()
        undoManager.clearAll()

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

        // New changes invalidate redo history (standard undo/redo behavior)
        if !isRedoing { undoManager.clearRedo() }

        let cellChange = CellChange(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue
        )

        // Check if this is an edit to an INSERTED row — O(1) dictionary lookup
        let insertKey = RowChangeKey(rowIndex: rowIndex, type: .insert)
        if let insertIndex = changeIndex[insertKey] {
            // Update stored values directly
            if var storedValues = insertedRowData[rowIndex] {
                if columnIndex < storedValues.count {
                    storedValues[columnIndex] = newValue
                    insertedRowData[rowIndex] = storedValues
                }
            }

            // Update/create CellChange for this column
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
            pushUndo(.cellEdit(
                rowIndex: rowIndex,
                columnIndex: columnIndex,
                columnName: columnName,
                previousValue: oldValue,
                newValue: newValue
            ))
            changedRowIndices.insert(rowIndex)
            hasChanges = !changes.isEmpty
            reloadVersion += 1
            return
        }

        // Find existing UPDATE row change or create new one — O(1) dictionary lookup
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

                // If value is back to original, remove the change
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

        pushUndo(.cellEdit(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            columnName: columnName,
            previousValue: oldValue,
            newValue: newValue
        ))
        hasChanges = !changes.isEmpty
        reloadVersion += 1
    }

    func recordRowDeletion(rowIndex: Int, originalRow: [String?]) {
        // New changes invalidate redo history (standard undo/redo behavior)
        if !isRedoing { undoManager.clearRedo() }

        // O(1) lookup + removal instead of linear removeAll
        removeChangeByKey(rowIndex: rowIndex, type: .update)
        modifiedCells.removeValue(forKey: rowIndex)

        let rowChange = RowChange(rowIndex: rowIndex, type: .delete, originalRow: originalRow)
        changes.append(rowChange)
        changeIndex[RowChangeKey(rowIndex: rowIndex, type: .delete)] = changes.count - 1
        deletedRowIndices.insert(rowIndex)
        changedRowIndices.insert(rowIndex)  // Track for granular reload
        pushUndo(.rowDeletion(rowIndex: rowIndex, originalRow: originalRow))
        hasChanges = true
        reloadVersion += 1
    }

    func recordBatchRowDeletion(rows: [(rowIndex: Int, originalRow: [String?])]) {
        // New changes invalidate redo history (never called from redo path)
        undoManager.clearRedo()

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
            changedRowIndices.insert(rowIndex)  // Track for granular reload
            batchData.append((rowIndex: rowIndex, originalRow: originalRow))
        }
        pushUndo(.batchRowDeletion(rows: batchData))
        hasChanges = true
        reloadVersion += 1
    }

    func recordRowInsertion(rowIndex: Int, values: [String?]) {
        // New changes invalidate redo history (never called from redo path)
        undoManager.clearRedo()

        insertedRowData[rowIndex] = values
        let rowChange = RowChange(rowIndex: rowIndex, type: .insert, cellChanges: [])
        changes.append(rowChange)
        changeIndex[RowChangeKey(rowIndex: rowIndex, type: .insert)] = changes.count - 1
        insertedRowIndices.insert(rowIndex)
        changedRowIndices.insert(rowIndex)  // Track for granular reload
        pushUndo(.rowInsertion(rowIndex: rowIndex))
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

        // Shift down indices for rows after the removed row
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

        // Rebuild needed after row index shifts
        rebuildChangeIndex()
        hasChanges = !changes.isEmpty
    }

    func undoBatchRowInsertion(rowIndices: [Int]) {
        guard !rowIndices.isEmpty else { return }

        let validRows = rowIndices.filter { insertedRowIndices.contains($0) }
        guard !validRows.isEmpty else { return }

        // Collect row values for undo/redo — O(1) lookup via changeIndex
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

        pushUndo(.batchRowInsertion(rowIndices: validRows, rowValues: rowValues))

        for deletedIndex in validRows.reversed() {
            var shiftedIndices = Set<Int>()
            for idx in insertedRowIndices {
                shiftedIndices.insert(idx > deletedIndex ? idx - 1 : idx)
            }
            insertedRowIndices = shiftedIndices

            for i in 0..<changes.count {
                if changes[i].rowIndex > deletedIndex {
                    changes[i].rowIndex -= 1
                }
            }
        }

        rebuildChangeIndex()
        hasChanges = !changes.isEmpty
    }

    // MARK: - Undo/Redo Stack Management

    func pushUndo(_ action: UndoAction) {
        undoManager.push(action)
    }

    func popUndo() -> UndoAction? {
        undoManager.popUndo()
    }

    func clearUndoStack() {
        undoManager.clearUndo()
    }

    func clearRedoStack() {
        undoManager.clearRedo()
    }

    /// Undo the last change and return details needed to update the UI
    func undoLastChange() -> (action: UndoAction, needsRowRemoval: Bool, needsRowRestore: Bool, restoreRow: [String?]?)? {
        guard let action = popUndo() else { return nil }

        undoManager.moveToRedo(action)

        switch action {
        case .cellEdit(let rowIndex, let columnIndex, let columnName, let previousValue, _):
            // O(1) lookup: try update first, then insert
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
            }
            changedRowIndices.insert(rowIndex)
            hasChanges = !changes.isEmpty
            reloadVersion += 1
            return (action, false, false, nil)

        case .rowInsertion(let rowIndex):
            undoRowInsertion(rowIndex: rowIndex)
            changedRowIndices.insert(rowIndex)
            return (action, true, false, nil)

        case .rowDeletion(let rowIndex, let originalRow):
            undoRowDeletion(rowIndex: rowIndex)
            changedRowIndices.insert(rowIndex)
            return (action, false, true, originalRow)

        case .batchRowDeletion(let rows):
            for (rowIndex, _) in rows.reversed() {
                undoRowDeletion(rowIndex: rowIndex)
                changedRowIndices.insert(rowIndex)
            }
            return (action, false, true, nil)

        case .batchRowInsertion(let rowIndices, let rowValues):
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
            }

            rebuildChangeIndex()
            hasChanges = !changes.isEmpty
            reloadVersion += 1
            return (action, true, false, nil)
        }
    }

    /// Redo the last undone change
    func redoLastChange() -> (action: UndoAction, needsRowInsert: Bool, needsRowDelete: Bool)? {
        guard let action = undoManager.popRedo() else { return nil }

        isRedoing = true
        defer { isRedoing = false }

        undoManager.moveToUndo(action)

        switch action {
        case .cellEdit(let rowIndex, let columnIndex, let columnName, let previousValue, let newValue):
            recordCellChange(
                rowIndex: rowIndex,
                columnIndex: columnIndex,
                columnName: columnName,
                oldValue: previousValue,
                newValue: newValue
            )
            _ = undoManager.popUndo()  // Remove extra undo
            changedRowIndices.insert(rowIndex)
            reloadVersion += 1
            return (action, false, false)

        case .rowInsertion(let rowIndex):
            insertedRowIndices.insert(rowIndex)
            let cellChanges = columns.enumerated().map { index, columnName in
                CellChange(
                    rowIndex: rowIndex,
                    columnIndex: index,
                    columnName: columnName,
                    oldValue: nil,
                    newValue: nil
                )
            }
            let rowChange = RowChange(rowIndex: rowIndex, type: .insert, cellChanges: cellChanges)
            changes.append(rowChange)
            changeIndex[RowChangeKey(rowIndex: rowIndex, type: .insert)] = changes.count - 1
            hasChanges = true
            changedRowIndices.insert(rowIndex)
            reloadVersion += 1
            return (action, true, false)

        case .rowDeletion(let rowIndex, let originalRow):
            recordRowDeletion(rowIndex: rowIndex, originalRow: originalRow)
            _ = undoManager.popUndo()
            changedRowIndices.insert(rowIndex)
            return (action, false, true)

        case .batchRowDeletion(let rows):
            for (rowIndex, originalRow) in rows {
                recordRowDeletion(rowIndex: rowIndex, originalRow: originalRow)
                _ = undoManager.popUndo()
                changedRowIndices.insert(rowIndex)
            }
            return (action, false, true)

        case .batchRowInsertion(let rowIndices, _):
            for rowIndex in rowIndices {
                removeChangeByKey(rowIndex: rowIndex, type: .insert)
                insertedRowIndices.remove(rowIndex)
                changedRowIndices.insert(rowIndex)
            }
            hasChanges = !changes.isEmpty
            reloadVersion += 1
            return (action, true, false)
        }
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

    /// Unified statement generation for both data grid and sidebar edits.
    /// Routes through plugin driver for NoSQL databases, falls back to SQLStatementGenerator for SQL.
    func generateSQL(
        for changes: [RowChange],
        insertedRowData: [Int: [String?]] = [:],
        deletedRowIndices: Set<Int> = [],
        insertedRowIndices: Set<Int> = []
    ) throws -> [ParameterizedStatement] {
        // Try plugin dispatch first (handles MongoDB, Redis, etcd, and future NoSQL plugins)
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

        // Safety: prevent SQL generation for NoSQL databases if plugin driver is unavailable
        if PluginManager.shared.editorLanguage(for: databaseType) != .sql {
            throw DatabaseError.queryFailed(
                "Cannot generate statements for \(databaseType.rawValue) — plugin driver not initialized"
            )
        }

        let generator = SQLStatementGenerator(
            tableName: tableName,
            columns: columns,
            primaryKeyColumn: primaryKeyColumn,
            databaseType: databaseType,
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

        // Validate DELETE coverage: batch DELETE produces 1 statement for N rows when PK exists,
        // so count statements != count rows. Instead check that all deletable rows got coverage.
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
        state.primaryKeyColumn = primaryKeyColumn
        state.columns = columns
        return state
    }

    func restoreState(from state: TabPendingChanges, tableName: String) {
        self.tableName = tableName
        self.changes = state.changes
        self.deletedRowIndices = state.deletedRowIndices
        self.insertedRowIndices = state.insertedRowIndices
        self.modifiedCells = state.modifiedCells
        self.insertedRowData = state.insertedRowData
        self.primaryKeyColumn = state.primaryKeyColumn
        self.columns = state.columns
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
