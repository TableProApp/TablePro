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
    let delta: Delta

    init(
        action: UndoAction,
        needsRowRemoval: Bool,
        needsRowRestore: Bool,
        restoreRow: [String?]?,
        delta: Delta = .none
    ) {
        self.action = action
        self.needsRowRemoval = needsRowRemoval
        self.needsRowRestore = needsRowRestore
        self.restoreRow = restoreRow
        self.delta = delta
    }
}

/// Manager for tracking and applying data changes
/// @MainActor ensures thread-safe access - critical for avoiding EXC_BAD_ACCESS
/// when multiple queries complete simultaneously (e.g., rapid sorting over SSH tunnel)
@MainActor @Observable
final class DataChangeManager: ChangeManaging {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DataChangeManager")

    private(set) var pending = PendingChanges()
    var hasChanges: Bool = false
    var reloadVersion: Int = 0

    var changes: [RowChange] { pending.changes }
    var rowChanges: [RowChange] { pending.changes }
    var insertedRowIndices: Set<Int> { pending.insertedRowIndices }

    var tableName: String = ""
    var primaryKeyColumns: [String] = []
    /// First PK column, for contexts that need a single column (paste, filters)
    var primaryKeyColumn: String? { primaryKeyColumns.first }
    var databaseType: DatabaseType = .mysql
    var pluginDriver: (any PluginDatabaseDriver)?

    var columns: [String] = []

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

    // MARK: - Configuration

    func clearChanges() {
        pending.clear()
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

        pending.clear()
        undoManagerProvider?()?.removeAllActions(withTarget: self)

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
        let recorded = pending.recordCellChange(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: originalRow
        )
        guard recorded else {
            hasChanges = !pending.isEmpty
            reloadVersion += 1
            return
        }
        registerUndo(actionName: String(localized: "Edit Cell")) { target in
            target.applyDataUndo(.cellEdit(
                rowIndex: rowIndex, columnIndex: columnIndex, columnName: columnName,
                previousValue: oldValue, newValue: newValue, originalRow: originalRow
            ))
        }
        hasChanges = !pending.isEmpty
        reloadVersion += 1
    }

    func recordRowDeletion(rowIndex: Int, originalRow: [String?]) {
        pending.recordRowDeletion(rowIndex: rowIndex, originalRow: originalRow)
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
        for (rowIndex, originalRow) in rows {
            pending.recordRowDeletion(rowIndex: rowIndex, originalRow: originalRow)
        }
        let batchData = rows
        registerUndo(actionName: String(localized: "Delete Rows")) { target in
            target.applyDataUndo(.batchRowDeletion(rows: batchData))
        }
        hasChanges = true
        reloadVersion += 1
    }

    func recordRowInsertion(rowIndex: Int, values: [String?]) {
        pending.recordRowInsertion(rowIndex: rowIndex, values: values)
        registerUndo(actionName: String(localized: "Insert Row")) { target in
            target.applyDataUndo(.rowInsertion(rowIndex: rowIndex))
        }
        hasChanges = true
        reloadVersion += 1
    }

    // MARK: - Undo Operations

    func undoRowDeletion(rowIndex: Int) {
        guard pending.undoRowDeletion(rowIndex: rowIndex) else { return }
        hasChanges = !pending.isEmpty
        reloadVersion += 1
    }

    func undoRowInsertion(rowIndex: Int) {
        guard pending.undoRowInsertion(rowIndex: rowIndex) else { return }
        hasChanges = !pending.isEmpty
        reloadVersion += 1
    }

    func undoBatchRowInsertion(rowIndices: [Int]) {
        let validRows = rowIndices.filter { pending.isRowInserted($0) }
        guard !validRows.isEmpty else { return }
        let rowValues = pending.undoBatchRowInsertion(rowIndices: validRows, columnCount: columns.count)
        registerUndo(actionName: String(localized: "Insert Rows")) { target in
            target.applyDataUndo(.batchRowInsertion(rowIndices: validRows, rowValues: rowValues))
        }
        hasChanges = !pending.isEmpty
        reloadVersion += 1
    }

    // MARK: - Core Undo Application

    private func applyDataUndo(_ action: UndoAction) {
        switch action {
        case .cellEdit(let rowIndex, let columnIndex, let columnName, let previousValue, let newValue, let originalRow):
            applyCellEditUndo(
                rowIndex: rowIndex, columnIndex: columnIndex, columnName: columnName,
                previousValue: previousValue, newValue: newValue, originalRow: originalRow,
                action: action
            )

        case .rowInsertion(let rowIndex):
            applyRowInsertionUndo(rowIndex: rowIndex, action: action)

        case .rowDeletion(let rowIndex, let originalRow):
            applyRowDeletionUndo(rowIndex: rowIndex, originalRow: originalRow, action: action)

        case .batchRowDeletion(let rows):
            applyBatchRowDeletionUndo(rows: rows, action: action)

        case .batchRowInsertion(let rowIndices, let rowValues):
            applyBatchRowInsertionUndo(rowIndices: rowIndices, rowValues: rowValues, action: action)
        }

        hasChanges = !pending.isEmpty
        reloadVersion += 1

        if let result = lastUndoResult {
            onUndoApplied?(result)
        }
    }

    private func applyCellEditUndo(
        rowIndex: Int, columnIndex: Int, columnName: String,
        previousValue: String?, newValue: String?, originalRow: [String?]?,
        action: UndoAction
    ) {
        registerUndo(actionName: String(localized: "Edit Cell")) { target in
            target.applyDataUndo(.cellEdit(
                rowIndex: rowIndex, columnIndex: columnIndex, columnName: columnName,
                previousValue: newValue, newValue: previousValue, originalRow: originalRow
            ))
        }

        if let updateChange = pending.change(forRow: rowIndex, type: .update) {
            if updateChange.cellChanges.contains(where: { $0.columnIndex == columnIndex }) {
                pending.revertUpdateCell(
                    rowIndex: rowIndex, columnIndex: columnIndex,
                    columnName: columnName, previousValue: previousValue
                )
            }
        } else if pending.change(forRow: rowIndex, type: .insert) != nil {
            pending.updateInsertedCellDirectly(
                rowIndex: rowIndex, columnIndex: columnIndex,
                columnName: columnName, newValue: previousValue
            )
        } else {
            pending.reapplyCellChange(
                rowIndex: rowIndex, columnIndex: columnIndex, columnName: columnName,
                originalDBValue: newValue, newValue: previousValue, originalRow: originalRow
            )
        }
        lastUndoResult = UndoResult(
            action: action, needsRowRemoval: false, needsRowRestore: false, restoreRow: nil,
            delta: .cellChanged(row: rowIndex, column: columnIndex)
        )
    }

    private func applyRowInsertionUndo(rowIndex: Int, action: UndoAction) {
        let savedValues = pending.savedInsertedValues(forRow: rowIndex)
        registerUndo(actionName: String(localized: "Insert Row")) { [savedValues] target in
            if let savedValues {
                target.pending.restoreInsertedValues(forRow: rowIndex, values: savedValues)
            }
            target.applyDataUndo(.rowInsertion(rowIndex: rowIndex))
        }

        if pending.isRowInserted(rowIndex) {
            _ = pending.undoRowInsertion(rowIndex: rowIndex)
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: true, needsRowRestore: false, restoreRow: nil,
                delta: .rowsRemoved(IndexSet(integer: rowIndex))
            )
        } else {
            pending.reinsertRow(rowIndex: rowIndex, columns: columns, savedValues: savedValues)
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: savedValues,
                delta: .rowsInserted(IndexSet(integer: rowIndex))
            )
        }
    }

    private func applyRowDeletionUndo(rowIndex: Int, originalRow: [String?], action: UndoAction) {
        registerUndo(actionName: String(localized: "Delete Row")) { target in
            target.applyDataUndo(.rowDeletion(rowIndex: rowIndex, originalRow: originalRow))
        }

        if pending.isRowDeleted(rowIndex) {
            _ = pending.undoRowDeletion(rowIndex: rowIndex)
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: originalRow,
                delta: .fullReplace
            )
        } else {
            pending.reapplyRowDeletion(rowIndex: rowIndex, originalRow: originalRow)
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: true, needsRowRestore: false, restoreRow: nil,
                delta: .fullReplace
            )
        }
    }

    private func applyBatchRowDeletionUndo(
        rows: [(rowIndex: Int, originalRow: [String?])], action: UndoAction
    ) {
        registerUndo(actionName: String(localized: "Delete Rows")) { target in
            target.applyDataUndo(.batchRowDeletion(rows: rows))
        }

        let isUndo = rows.contains { pending.isRowDeleted($0.rowIndex) }
        if isUndo {
            for (rowIndex, _) in rows.reversed() {
                _ = pending.undoRowDeletion(rowIndex: rowIndex)
            }
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: nil,
                delta: .fullReplace
            )
        } else {
            for (rowIndex, originalRow) in rows {
                pending.reapplyRowDeletion(rowIndex: rowIndex, originalRow: originalRow)
            }
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: true, needsRowRestore: false, restoreRow: nil,
                delta: .fullReplace
            )
        }
    }

    private func applyBatchRowInsertionUndo(
        rowIndices: [Int], rowValues: [[String?]], action: UndoAction
    ) {
        registerUndo(actionName: String(localized: "Insert Rows")) { target in
            target.applyDataUndo(.batchRowInsertion(rowIndices: rowIndices, rowValues: rowValues))
        }

        let firstInserted = rowIndices.first.map { pending.isRowInserted($0) } ?? false
        let indices = IndexSet(rowIndices)
        if firstInserted {
            _ = pending.undoBatchRowInsertion(rowIndices: rowIndices, columnCount: columns.count)
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: true, needsRowRestore: false, restoreRow: nil,
                delta: .rowsRemoved(indices)
            )
        } else {
            pending.reinsertBatch(rowIndices: rowIndices, rowValues: rowValues, columns: columns)
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: nil,
                delta: .rowsInserted(indices)
            )
        }
    }

    // MARK: - SQL Generation

    func generateSQL() throws -> [ParameterizedStatement] {
        try generateSQL(
            for: pending.changes,
            insertedRowData: pending.insertedRowData,
            deletedRowIndices: pending.deletedRowIndices,
            insertedRowIndices: pending.insertedRowIndices
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

        let generator = try SQLStatementGenerator(
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
        for change in pending.changes where change.type == .update {
            for cellChange in change.cellChanges {
                originals.append((
                    rowIndex: change.rowIndex,
                    columnIndex: cellChange.columnIndex,
                    value: cellChange.oldValue
                ))
            }
        }
        return originals
    }

    func discardChanges() {
        pending.clear()
        hasChanges = false
        reloadVersion += 1
    }

    // MARK: - Per-Tab State Management

    func saveState() -> TabChangeSnapshot {
        pending.snapshot(primaryKeyColumns: primaryKeyColumns, columns: columns)
    }

    func restoreState(from state: TabChangeSnapshot, tableName: String, databaseType: DatabaseType) {
        self.tableName = tableName
        self.columns = state.columns
        self.primaryKeyColumns = state.primaryKeyColumns
        self.databaseType = databaseType
        pending.restore(from: state)
        self.hasChanges = !pending.isEmpty
    }

    // MARK: - O(1) Lookups

    func isRowDeleted(_ rowIndex: Int) -> Bool {
        pending.isRowDeleted(rowIndex)
    }

    func isRowInserted(_ rowIndex: Int) -> Bool {
        pending.isRowInserted(rowIndex)
    }

    func isCellModified(rowIndex: Int, columnIndex: Int) -> Bool {
        pending.isCellModified(rowIndex: rowIndex, columnIndex: columnIndex)
    }

    func getModifiedColumnsForRow(_ rowIndex: Int) -> Set<Int> {
        pending.modifiedColumns(forRow: rowIndex)
    }
}
