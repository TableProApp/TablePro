//
//  DataChangeManager.swift
//  TablePro
//
//  Manager for tracking data changes with O(1) lookups.
//  Delegates SQL generation to SQLStatementGenerator.
//  Uses Apple's UndoManager (NSUndoManager) for undo/redo stack management.
//

import Combine
import Foundation
import os
import TableProPluginKit

struct UndoResult {
    let action: UndoAction
    let needsRowRemoval: Bool
    let needsRowRestore: Bool
    let restoreRow: [PluginCellValue]?
    /// The columns `restoreRow` has no field for.
    let restoreAbsentColumns: Set<Int>
    let delta: Delta

    init(
        action: UndoAction,
        needsRowRemoval: Bool,
        needsRowRestore: Bool,
        restoreRow: [PluginCellValue]?,
        restoreAbsentColumns: Set<Int> = [],
        delta: Delta = .none
    ) {
        self.action = action
        self.needsRowRemoval = needsRowRemoval
        self.needsRowRestore = needsRowRestore
        self.restoreRow = restoreRow
        self.restoreAbsentColumns = restoreAbsentColumns
        self.delta = delta
    }
}

/// Manager for tracking and applying data changes
/// @MainActor ensures thread-safe access - critical for avoiding EXC_BAD_ACCESS
/// when multiple queries complete simultaneously (e.g., rapid sorting over SSH tunnel)
@MainActor
final class DataChangeManager: ObservableObject, ChangeManaging {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "DataChangeManager")

    @Published private(set) var pending = PendingChanges()
    @Published var hasChanges: Bool = false
    @Published var reloadVersion: Int = 0

    var changes: [RowChange] { pending.changes }
    var rowChanges: [RowChange] { pending.changes }
    var insertedRowIDs: Set<RowID> { pending.insertedRowIDs }
    var deletedRowIDs: Set<RowID> { pending.deletedRowIDs }

    @Published var tableName: String = ""
    @Published var schemaName: String?
    @Published var primaryKeyColumns: [String] = []
    /// First PK column, for contexts that need a single column (paste, filters)
    var primaryKeyColumn: String? { primaryKeyColumns.first }
    /// Columns the server computes. They reject any written value, so they are
    /// never editable and never appear in a generated INSERT or UPDATE.
    @Published var generatedColumns: Set<String> = []
    @Published private(set) var rowMatchPolicy: RowMatchPolicy = .none
    @Published var databaseType: DatabaseType?
    @Published var pluginDriver: (any PluginDatabaseDriver)?

    @Published var columns: [String] = []

    @Published var undoManagerProvider: (() -> UndoManager?)?
    @Published var onUndoApplied: ((UndoResult) -> Void)?

    @Published private var lastUndoResult: UndoResult?

    /// The cells an open editor is still typing into, held back from the undo stack until the run
    /// ends so a typed word is one step rather than one per character.
    ///
    /// Each entry keeps the value the cell held when the run started and takes the newest value on
    /// every keystroke, so the step that is finally registered restores the whole word and its redo
    /// carries the final value rather than the first character's.
    private struct CoalescedCellEdit {
        let rowID: RowID
        let columnIndex: Int
        let columnName: String
        let previousValue: PluginCellValue
        var newValue: PluginCellValue
        let originalRow: [PluginCellValue]?
        var absence: FieldAbsence

        var isNoOp: Bool {
            previousValue == newValue && absence.wasAbsent == absence.isAbsent
        }
    }

    private struct CoalescedCellKey: Hashable {
        let rowID: RowID
        let columnIndex: Int
    }

    private var coalescedEdits: [CoalescedCellKey: CoalescedCellEdit] = [:]
    private var coalescedOrder: [CoalescedCellKey] = []

    /// Whether a typed edit is waiting to become an undo step. The Edit menu reads it, because the
    /// undo manager has nothing registered yet while the run is open.
    var hasCoalescedUndoRun: Bool { !coalescedOrder.isEmpty }

    // MARK: - Undo/Redo Properties

    var canUndo: Bool { undoManagerProvider?()?.canUndo ?? false }
    var canRedo: Bool { undoManagerProvider?()?.canRedo ?? false }

    private func registerUndo(actionName: String, _ handler: @escaping (DataChangeManager) -> Void) {
        guard let undoManager = undoManagerProvider?() else { return }
        /// Any other action ends the run, so its own step lands after the typing it interrupted
        /// rather than inside it. Undo and redo replay register too, and flushing there would fold
        /// the run into the step being replayed.
        if !undoManager.isUndoing, !undoManager.isRedoing {
            endCoalescedUndoRun()
        }
        let opensOwnGroup = !undoManager.groupsByEvent && undoManager.groupingLevel == 0
        if opensOwnGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self, handler: handler)
        undoManager.setActionName(actionName)
        if opensOwnGroup { undoManager.endUndoGrouping() }
    }

    // MARK: - Configuration

    func clearChanges() {
        discardCoalescedUndoRun()
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
        schemaName: String? = nil,
        columns: [String],
        primaryKeyColumns: [String],
        databaseType: DatabaseType,
        generatedColumns: Set<String>,
        rowMatchPolicy: RowMatchPolicy = .none,
        triggerReload: Bool = true
    ) {
        self.tableName = tableName
        self.schemaName = schemaName
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.databaseType = databaseType
        self.generatedColumns = generatedColumns
        self.rowMatchPolicy = rowMatchPolicy

        discardCoalescedUndoRun()
        pending.clear()
        undoManagerProvider?()?.removeAllActions(withTarget: self)

        hasChanges = false
        if triggerReload {
            reloadVersion += 1
        }
    }

    func setPrimaryKeyColumns(_ primaryKeyColumns: [String]) {
        self.primaryKeyColumns = primaryKeyColumns
    }

    func setGeneratedColumns(_ generatedColumns: Set<String>) {
        self.generatedColumns = generatedColumns
    }

    func setRowMatchPolicy(_ rowMatchPolicy: RowMatchPolicy) {
        self.rowMatchPolicy = rowMatchPolicy
    }

    /// Whether the engine tells a missing field from NULL, which is what offers Remove Field and
    /// starts a new row with its fields missing.
    var supportsFieldRemoval: Bool {
        guard let databaseType else { return false }
        return PluginManager.shared.supportsFieldRemoval(for: databaseType)
    }

    /// Whether the app may send a value for this column at all: the server computes or allocates it,
    /// or the driver declares it immutable, as MongoDB does for `_id`. Both halves belong here,
    /// because this is the boundary every staging path crosses and the grid's own copy of the
    /// question does not cover the paths that reach the model directly.
    func isColumnWritable(_ columnName: String) -> Bool {
        guard !generatedColumns.contains(columnName) else { return false }
        guard let databaseType else { return true }
        return !PluginManager.shared.immutableColumns(for: databaseType).contains(columnName)
    }

    /// The columns among `columns` the app may not send a value for, which the inspector shows
    /// read-only. The same answer as `isColumnWritable`, so the inspector cannot offer an edit that
    /// staging then refuses and leaves pending in the field.
    func unwritableColumns(among columns: [String]) -> Set<String> {
        Set(columns.filter { !isColumnWritable($0) })
    }

    // MARK: - Change Tracking

    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]? = nil
    ) {
        recordCellChange(
            rowID: rowID, columnIndex: columnIndex, columnName: columnName,
            oldValue: oldValue, newValue: newValue, originalRow: originalRow,
            absence: FieldAbsence()
        )
    }

    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?,
        absence: FieldAbsence
    ) {
        record(
            rowID: rowID, columnIndex: columnIndex, columnName: columnName,
            oldValue: oldValue, newValue: newValue, originalRow: originalRow,
            absence: absence, coalescesWithPrevious: false
        )
    }

    /// One keystroke from an editor that is still open. The step it belongs to is registered when
    /// the run ends, so a typed word is one undo rather than one per character.
    func recordTypedCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]? = nil,
        absence: FieldAbsence = FieldAbsence()
    ) {
        record(
            rowID: rowID, columnIndex: columnIndex, columnName: columnName,
            oldValue: oldValue, newValue: newValue, originalRow: originalRow,
            absence: absence, coalescesWithPrevious: true
        )
    }

    private func record(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?,
        absence: FieldAbsence,
        coalescesWithPrevious: Bool
    ) {
        /// The last gate before a change becomes pending, and the only one every path crosses. The
        /// grid's own check covers the inline editor and the Set Value menu; paste, Fill Column and
        /// the row inspector reach here directly, so a column the server owns could be staged, be
        /// filtered out again during statement generation, and be cleared by a save that reported
        /// success over the changes it did write.
        guard isColumnWritable(columnName) else {
            Self.logger.warning(
                "Refusing an edit to server-owned column '\(columnName, privacy: .public)' in table '\(self.tableName, privacy: .public)'"
            )
            return
        }
        let recorded = pending.recordCellChange(
            rowID: rowID,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: originalRow,
            absence: absence
        )
        guard recorded else {
            hasChanges = !pending.isEmpty
            return
        }
        if coalescesWithPrevious {
            bufferCoalescedEdit(
                rowID: rowID, columnIndex: columnIndex, columnName: columnName,
                oldValue: oldValue, newValue: newValue, originalRow: originalRow, absence: absence
            )
        } else {
            registerUndo(actionName: String(localized: "Edit Cell")) { target in
                target.applyDataUndo(.cellEdit(
                    rowID: rowID, columnIndex: columnIndex, columnName: columnName,
                    previousValue: oldValue, newValue: newValue, originalRow: originalRow,
                    absence: absence
                ))
            }
        }
        hasChanges = !pending.isEmpty
    }

    private func bufferCoalescedEdit(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?,
        absence: FieldAbsence
    ) {
        let key = CoalescedCellKey(rowID: rowID, columnIndex: columnIndex)
        if var existing = coalescedEdits[key] {
            existing.newValue = newValue
            existing.absence.isAbsent = absence.isAbsent
            coalescedEdits[key] = existing
            return
        }
        coalescedEdits[key] = CoalescedCellEdit(
            rowID: rowID, columnIndex: columnIndex, columnName: columnName,
            previousValue: oldValue, newValue: newValue, originalRow: originalRow, absence: absence
        )
        coalescedOrder.append(key)
    }

    /// Registers the run's cells as one undo step, in the order they were first written.
    ///
    /// A cell typed back to where it started contributes nothing: registering it would leave a step
    /// that restores a value the cell already holds, and undoing it would record a pending change
    /// over a value that already matches the server.
    func endCoalescedUndoRun() {
        guard !coalescedOrder.isEmpty else { return }
        let edits = coalescedOrder.compactMap { coalescedEdits[$0] }.filter { !$0.isNoOp }
        discardCoalescedUndoRun()
        guard !edits.isEmpty, let undoManager = undoManagerProvider?() else { return }

        undoManager.beginUndoGrouping()
        for edit in edits {
            undoManager.registerUndo(withTarget: self) { target in
                target.applyDataUndo(.cellEdit(
                    rowID: edit.rowID, columnIndex: edit.columnIndex, columnName: edit.columnName,
                    previousValue: edit.previousValue, newValue: edit.newValue, originalRow: edit.originalRow,
                    absence: edit.absence
                ))
            }
        }
        undoManager.setActionName(String(localized: "Edit Cell"))
        undoManager.endUndoGrouping()
    }

    private func discardCoalescedUndoRun() {
        coalescedEdits.removeAll()
        coalescedOrder.removeAll()
    }

    func recordRowDeletion(rowID: RowID, originalRow: [PluginCellValue], absentColumns: Set<Int> = []) {
        pending.recordRowDeletion(rowID: rowID, originalRow: originalRow, absentColumns: absentColumns)
        registerUndo(actionName: String(localized: "Delete Row")) { target in
            target.applyDataUndo(.rowDeletion(rowID: rowID, originalRow: originalRow, absentColumns: absentColumns))
        }
        hasChanges = true
    }

    func recordBatchRowDeletion(
        rows: [(rowID: RowID, originalRow: [PluginCellValue])],
        absentColumns: [RowID: Set<Int>] = [:]
    ) {
        guard rows.count > 1 else {
            if let row = rows.first {
                recordRowDeletion(
                    rowID: row.rowID, originalRow: row.originalRow, absentColumns: absentColumns[row.rowID] ?? []
                )
            }
            return
        }
        for (rowID, originalRow) in rows {
            pending.recordRowDeletion(rowID: rowID, originalRow: originalRow, absentColumns: absentColumns[rowID] ?? [])
        }
        let batchData = rows
        registerUndo(actionName: String(localized: "Delete Rows")) { target in
            target.applyDataUndo(.batchRowDeletion(rows: batchData, absentColumns: absentColumns))
        }
        hasChanges = true
    }

    func recordRowInsertion(rowID: RowID, values: [PluginCellValue], absentColumns: Set<Int> = []) {
        pending.recordRowInsertion(rowID: rowID, values: values, absentColumns: absentColumns)
        registerUndo(actionName: String(localized: "Insert Row")) { target in
            target.applyDataUndo(.rowInsertion(rowID: rowID))
        }
        hasChanges = true
    }

    // MARK: - Undo Operations

    func undoRowDeletion(rowID: RowID) {
        guard pending.undoRowDeletion(rowID: rowID) else { return }
        hasChanges = !pending.isEmpty
    }

    func undoBatchRowInsertion(rows: [InsertedRowLocation]) {
        let validRows = rows.filter { pending.isRowInserted($0.rowID) }
        guard !validRows.isEmpty else { return }
        let rowAbsentColumns = validRows.map { pending.insertedAbsentColumns(forRow: $0.rowID) }
        let rowValues = pending.undoBatchRowInsertion(
            rowIDs: validRows.map(\.rowID), columnCount: columns.count
        )
        registerUndo(actionName: String(localized: "Insert Rows")) { target in
            target.applyDataUndo(.batchRowInsertion(
                rows: validRows, rowValues: rowValues, rowAbsentColumns: rowAbsentColumns
            ))
        }
        hasChanges = !pending.isEmpty
    }

    // MARK: - Core Undo Application

    private func applyDataUndo(_ action: UndoAction) {
        switch action {
        case .cellEdit(let rowID, let columnIndex, let columnName, let previousValue, let newValue, let originalRow,
                       let absence):
            applyCellEditUndo(
                rowID: rowID, columnIndex: columnIndex, columnName: columnName,
                previousValue: previousValue, newValue: newValue, originalRow: originalRow,
                absence: absence, action: action
            )

        case .rowInsertion(let rowID, let image):
            applyRowInsertionUndo(rowID: rowID, restoring: image, action: action)

        case .rowDeletion(let rowID, let originalRow, let absentColumns):
            applyRowDeletionUndo(rowID: rowID, originalRow: originalRow, absentColumns: absentColumns, action: action)

        case .batchRowDeletion(let rows, let absentColumns):
            applyBatchRowDeletionUndo(rows: rows, absentColumns: absentColumns, action: action)

        case .batchRowInsertion(let rows, let rowValues, let rowAbsentColumns):
            applyBatchRowInsertionUndo(
                rows: rows, rowValues: rowValues, rowAbsentColumns: rowAbsentColumns, action: action
            )
        }

        hasChanges = !pending.isEmpty

        if let result = lastUndoResult {
            onUndoApplied?(result)
        }
    }

    private func applyCellEditUndo(
        rowID: RowID, columnIndex: Int, columnName: String,
        previousValue: PluginCellValue, newValue: PluginCellValue, originalRow: [PluginCellValue]?,
        absence: FieldAbsence, action: UndoAction
    ) {
        registerUndo(actionName: String(localized: "Edit Cell")) { target in
            target.applyDataUndo(.cellEdit(
                rowID: rowID, columnIndex: columnIndex, columnName: columnName,
                previousValue: newValue, newValue: previousValue, originalRow: originalRow,
                absence: absence.reversed
            ))
        }

        if let updateChange = pending.change(forRow: rowID, type: .update) {
            if updateChange.cellChanges.contains(where: { $0.columnIndex == columnIndex }) {
                pending.revertUpdateCell(
                    rowID: rowID, columnIndex: columnIndex,
                    columnName: columnName, previousValue: previousValue,
                    previousIsAbsent: absence.wasAbsent
                )
            }
        } else if pending.change(forRow: rowID, type: .insert) != nil {
            pending.updateInsertedCellDirectly(
                rowID: rowID, columnIndex: columnIndex,
                columnName: columnName, newValue: previousValue, isAbsent: absence.wasAbsent
            )
        } else {
            pending.reapplyCellChange(
                rowID: rowID,
                columnIndex: columnIndex, columnName: columnName,
                originalDBValue: newValue, newValue: previousValue, originalRow: originalRow,
                absence: absence.reversed
            )
        }
        lastUndoResult = UndoResult(
            action: action, needsRowRemoval: false, needsRowRestore: false, restoreRow: nil
        )
    }

    /// Undoing takes the row out and hands the redo everything it held. Redoing puts that back,
    /// and the undo registered then reads the row as it stands again.
    private func applyRowInsertionUndo(rowID: RowID, restoring image: InsertedRowImage?, action: UndoAction) {
        guard pending.isRowInserted(rowID) else {
            registerUndo(actionName: String(localized: "Insert Row")) { target in
                target.applyDataUndo(.rowInsertion(rowID: rowID))
            }
            let absentColumns = image?.absentColumns ?? []
            pending.reinsertRow(
                rowID: rowID, columns: columns, savedValues: image?.values, absentColumns: absentColumns
            )
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: image?.values,
                restoreAbsentColumns: absentColumns
            )
            return
        }

        let removed = InsertedRowImage(
            values: pending.savedInsertedValues(forRow: rowID),
            absentColumns: pending.insertedAbsentColumns(forRow: rowID)
        )
        registerUndo(actionName: String(localized: "Insert Row")) { target in
            target.applyDataUndo(.rowInsertion(rowID: rowID, restoring: removed))
        }
        _ = pending.undoRowInsertion(rowID: rowID)
        lastUndoResult = UndoResult(
            action: action, needsRowRemoval: true, needsRowRestore: false, restoreRow: nil
        )
    }

    private func applyRowDeletionUndo(
        rowID: RowID, originalRow: [PluginCellValue], absentColumns: Set<Int>, action: UndoAction
    ) {
        registerUndo(actionName: String(localized: "Delete Row")) { target in
            target.applyDataUndo(.rowDeletion(rowID: rowID, originalRow: originalRow, absentColumns: absentColumns))
        }

        if pending.isRowDeleted(rowID) {
            _ = pending.undoRowDeletion(rowID: rowID)
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: originalRow,
                delta: .fullReplace
            )
        } else {
            pending.reapplyRowDeletion(rowID: rowID, originalRow: originalRow, absentColumns: absentColumns)
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: true, needsRowRestore: false, restoreRow: nil,
                delta: .fullReplace
            )
        }
    }

    private func applyBatchRowDeletionUndo(
        rows: [(rowID: RowID, originalRow: [PluginCellValue])],
        absentColumns: [RowID: Set<Int>],
        action: UndoAction
    ) {
        registerUndo(actionName: String(localized: "Delete Rows")) { target in
            target.applyDataUndo(.batchRowDeletion(rows: rows, absentColumns: absentColumns))
        }

        let isUndo = rows.contains { pending.isRowDeleted($0.rowID) }
        if isUndo {
            for (rowID, _) in rows.reversed() {
                _ = pending.undoRowDeletion(rowID: rowID)
            }
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: nil,
                delta: .fullReplace
            )
        } else {
            for (rowID, originalRow) in rows {
                pending.reapplyRowDeletion(
                    rowID: rowID, originalRow: originalRow, absentColumns: absentColumns[rowID] ?? []
                )
            }
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: true, needsRowRestore: false, restoreRow: nil,
                delta: .fullReplace
            )
        }
    }

    private func applyBatchRowInsertionUndo(
        rows: [InsertedRowLocation], rowValues: [[PluginCellValue]], rowAbsentColumns: [Set<Int>], action: UndoAction
    ) {
        registerUndo(actionName: String(localized: "Insert Rows")) { target in
            target.applyDataUndo(.batchRowInsertion(
                rows: rows, rowValues: rowValues, rowAbsentColumns: rowAbsentColumns
            ))
        }

        let rowIDs = rows.map(\.rowID)
        let firstInserted = rowIDs.first.map { pending.isRowInserted($0) } ?? false
        if firstInserted {
            _ = pending.undoBatchRowInsertion(rowIDs: rowIDs, columnCount: columns.count)
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: true, needsRowRestore: false, restoreRow: nil
            )
        } else {
            pending.reinsertBatch(
                rowIDs: rowIDs, rowValues: rowValues, rowAbsentColumns: rowAbsentColumns, columns: columns
            )
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: nil
            )
        }
    }

    // MARK: - SQL Generation

    func generateSQL() throws -> [ParameterizedStatement] {
        try generateSQL(
            for: pending.changes,
            insertedRowData: pending.insertedRowData,
            deletedRowIDs: pending.deletedRowIDs,
            insertedRowIDs: pending.insertedRowIDs
        )
    }

    func generateSQL(
        for changes: [RowChange],
        insertedRowData: [RowID: [PluginCellValue]] = [:],
        deletedRowIDs: Set<RowID> = [],
        insertedRowIDs: Set<RowID> = []
    ) throws -> [ParameterizedStatement] {
        try statementFactory().statements(
            for: changes,
            insertedRowData: insertedRowData,
            deletedRowIDs: deletedRowIDs,
            insertedRowIDs: insertedRowIDs
        )
    }

    /// How the pending changes reach the database, and what each row looked like on either side.
    ///
    /// The steps are what runs. The operations are what a rewind would need, and they are built
    /// from the change set rather than read back off the statements, so a driver that writes its
    /// own statements still produces a complete record.
    func buildRowWrites(database: String, schema: String?, containsTableOperation: Bool) throws -> RowWriteBuild {
        let factory = try statementFactory()
        let operations = RowWriteOperationBuilder.operations(
            from: pending.changes,
            insertedRowData: pending.insertedRowData,
            deletedRowIDs: pending.deletedRowIDs,
            insertedRowIDs: pending.insertedRowIDs,
            target: DataWriteTarget(database: database, schema: schema, table: tableName),
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            generatedColumns: generatedColumns,
            containsTableOperation: containsTableOperation
        )

        let steps: [DataWriteStep]
        switch try factory.rowWriteStatements(
            for: pending.changes,
            insertedRowData: pending.insertedRowData,
            deletedRowIDs: pending.deletedRowIDs,
            insertedRowIDs: pending.insertedRowIDs
        ) {
        case .counted(let attributed):
            steps = attributed.map {
                DataWriteStep(
                    kind: .rowWrite,
                    statement: $0.statement,
                    expectedRowCount: $0.rowCount,
                    tableName: tableName,
                    matchesRowsWithoutKey: primaryKeyColumns.isEmpty && $0.kind != .insert
                )
            }
        case .driverWritten(let statements):
            steps = statements.map {
                DataWriteStep(kind: .rowWrite, statement: $0, expectedRowCount: nil, tableName: tableName)
            }
        }
        return RowWriteBuild(steps: steps, operations: operations)
    }

    func statementFactory() throws -> RowChangeStatementFactory {
        guard let databaseType else {
            throw DatabaseError.queryFailed("Cannot generate statements: table dialect not configured")
        }
        return RowChangeStatementFactory(
            tableName: tableName,
            schemaName: schemaName,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            generatedColumns: generatedColumns,
            rowMatchPolicy: rowMatchPolicy,
            databaseType: databaseType,
            pluginDriver: pluginDriver
        )
    }

    // MARK: - Actions

    func getOriginalValues() -> [(rowID: RowID, columnIndex: Int, value: PluginCellValue, isAbsent: Bool)] {
        var originals: [(rowID: RowID, columnIndex: Int, value: PluginCellValue, isAbsent: Bool)] = []
        for change in pending.changes where change.type == .update {
            for cellChange in change.cellChanges {
                originals.append((
                    rowID: change.rowID,
                    columnIndex: cellChange.columnIndex,
                    value: cellChange.oldValue,
                    isAbsent: cellChange.oldIsAbsent
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

    func restoreState(
        from state: TabChangeSnapshot,
        tableName: String,
        schemaName: String? = nil,
        databaseType: DatabaseType,
        generatedColumns: Set<String>,
        rowMatchPolicy: RowMatchPolicy = .none
    ) {
        self.tableName = tableName
        self.schemaName = schemaName
        self.columns = state.columns
        self.primaryKeyColumns = state.primaryKeyColumns
        self.databaseType = databaseType
        self.generatedColumns = generatedColumns
        self.rowMatchPolicy = rowMatchPolicy
        discardCoalescedUndoRun()
        pending.restore(from: state)
        self.hasChanges = !pending.isEmpty
    }

    // MARK: - O(1) Lookups

    func isRowDeleted(_ rowID: RowID) -> Bool {
        pending.isRowDeleted(rowID)
    }

    func isRowInserted(_ rowID: RowID) -> Bool {
        pending.isRowInserted(rowID)
    }

    func isCellModified(rowID: RowID, columnIndex: Int) -> Bool {
        pending.isCellModified(rowID: rowID, columnIndex: columnIndex)
    }

    func getModifiedColumnsForRow(_ rowID: RowID) -> Set<Int> {
        pending.modifiedColumns(forRow: rowID)
    }
}
