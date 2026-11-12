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

    // Not @Published: the wrapper has no in-place access, so each mutation copied every pending change.
    private(set) var pending = PendingChanges()
    @Published var hasChanges: Bool = false
    @Published var reloadVersion: Int = 0

    var changes: [RowChange] { pending.changes }
    var rowChanges: [RowChange] { pending.changes }
    var insertedRowIDs: Set<RowID> { pending.insertedRowIDs }
    var deletedRowIDs: Set<RowID> { pending.deletedRowIDs }
    var modifiedCells: [RowID: Set<Int>] { pending.modifiedCells }

    @Published var tableName: String = ""
    @Published var schemaName: String?
    @Published var primaryKeyColumns: [String] = []
    /// First PK column, for contexts that need a single column (paste, filters)
    var primaryKeyColumn: String? { primaryKeyColumns.first }
    /// Columns the server computes. They reject any written value, so they are
    /// never editable and never appear in a generated INSERT or UPDATE.
    @Published var generatedColumns: Set<String> = []
    @Published private(set) var rowMatchPolicy: RowMatchPolicy = .none
    /// The type each column was read as, by column name. A driver that writes its own statements types each value by it,
    /// so it travels with the columns rather than being looked up again when the save is built.
    private(set) var columnTypeNames: [String: String] = [:]
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
        var expression: ExpressionTransition

        var isNoOp: Bool {
            previousValue == newValue && absence.wasAbsent == absence.isAbsent
                && expression.wasExpression == expression.isExpression
        }
    }

    private struct CoalescedCellKey: Hashable {
        let rowID: RowID
        let columnIndex: Int
    }

    private var coalescedEdits: [CoalescedCellKey: CoalescedCellEdit] = [:]
    private var loadedValues: [RowID: [Int: PluginCellValue]] = [:]
    private var coalescedOrder: [CoalescedCellKey] = []

    // Process-wide, so a run restored from another tab never shares an id with a new command.
    private static var lastActionID = 0
    private var commandAction: Int?
    private var typingAction: Int?

    private static func newActionID() -> Int {
        lastActionID += 1
        return lastActionID
    }

    // One undo step over many cells, so a row it writes more than once stays one write in the save.
    func recordAsOneAction(_ body: () -> Void) {
        guard commandAction == nil else {
            body()
            return
        }
        commandAction = Self.newActionID()
        defer { commandAction = nil }
        body()
    }

    private func typingRunAction() -> Int {
        if let typingAction { return typingAction }
        let action = Self.newActionID()
        typingAction = action
        return action
    }

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
        objectWillChange.send()
        pending.clear()
        hasChanges = false
        reloadVersion += 1
    }

    func clearChangesAndUndoHistory() {
        clearChanges()
        loadedValues.removeAll()
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
        columnTypeNames: [String: String] = [:],
        triggerReload: Bool = true
    ) {
        self.tableName = tableName
        self.schemaName = schemaName
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.databaseType = databaseType
        self.generatedColumns = generatedColumns
        self.rowMatchPolicy = rowMatchPolicy
        self.columnTypeNames = columnTypeNames

        discardUndoHistory()
        objectWillChange.send()
        pending.clear()

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

    /// Asked of the driver instance, not of the plugin's metadata: ScyllaDB is a variant of the Cassandra plugin and
    /// takes its curated entry, not the plugin's flags.
    var cellWriterSupport: CellWriterSupport {
        guard let pluginDriver else { return .host }
        let capabilities = pluginDriver.capabilities
        return CellWriterSupport(
            acceptsExpressions: capabilities.contains(.cellExpressions),
            acceptsUUIDText: capabilities.contains(.uuidCellText)
        )
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
        recordCellChange(
            rowID: rowID, columnIndex: columnIndex, columnName: columnName,
            oldValue: oldValue, newValue: newValue, originalRow: originalRow,
            absence: absence, isExpression: false
        )
    }

    /// `isExpression` stages `newValue`, a `.text` holding SQL from `CellExpressionVocabulary`, to be written
    /// unquoted.
    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?,
        absence: FieldAbsence,
        isExpression: Bool
    ) {
        record(
            rowID: rowID, columnIndex: columnIndex, columnName: columnName,
            oldValue: oldValue, newValue: newValue, originalRow: originalRow,
            absence: absence, isExpression: isExpression, coalescesWithPrevious: false
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
        absence: FieldAbsence = FieldAbsence(),
        isExpression: Bool = false
    ) {
        record(
            rowID: rowID, columnIndex: columnIndex, columnName: columnName,
            oldValue: oldValue, newValue: newValue, originalRow: originalRow,
            absence: absence, isExpression: isExpression, coalescesWithPrevious: true
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
        isExpression: Bool,
        coalescesWithPrevious: Bool
    ) {
        /// The last gate before a change becomes pending, and the only one every path crosses. The
        /// grid's own check covers the inline editor and the Set Value menu; paste, Fill Column and
        /// the row inspector reach here directly, so a column the server owns could be staged, be
        /// filtered out again during statement generation, and be cleared by a save that reported
        /// success over the changes it did write.
        guard isColumnWritable(columnName) else {
            Self.logger.warning(
                "Refusing an edit to server-owned column '\(columnName, privacy: .private(mask: .hash))' in table '\(self.tableName, privacy: .private(mask: .hash))'"
            )
            return
        }
        let expression = ExpressionTransition(
            wasExpression: pending.isExpression(rowID: rowID, columnIndex: columnIndex),
            isExpression: isExpression
        )
        // The grid's row shows the row's other pending cells; an undo that has to stage the row again needs it as read.
        var absence = absence
        let originalRow = originalRow.map { shown in
            let image = pending.imageAsRead(ofRow: rowID, current: shown, absentColumns: absence.originalRow)
            absence.originalRow = image.absentColumns
            return image.row
        }
        let action = coalescesWithPrevious ? typingRunAction() : commandAction ?? Self.newActionID()
        objectWillChange.send()
        let recorded = pending.recordCellChange(
            rowID: rowID,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: originalRow,
            absence: absence,
            isExpression: isExpression,
            action: action
        )
        guard recorded else {
            hasChanges = !pending.isEmpty
            return
        }
        if coalescesWithPrevious {
            bufferCoalescedEdit(
                rowID: rowID, columnIndex: columnIndex, columnName: columnName,
                oldValue: oldValue, newValue: newValue, originalRow: originalRow,
                absence: absence, expression: expression
            )
        } else {
            registerUndo(actionName: String(localized: "Edit Cell")) { target in
                target.applyDataUndo(
                    .cellEdit(
                        rowID: rowID, columnIndex: columnIndex, columnName: columnName,
                        previousValue: oldValue, newValue: newValue, originalRow: originalRow,
                        absence: absence, expression: expression
                    ),
                    actionID: action
                )
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
        absence: FieldAbsence,
        expression: ExpressionTransition
    ) {
        let key = CoalescedCellKey(rowID: rowID, columnIndex: columnIndex)
        if var existing = coalescedEdits[key] {
            existing.newValue = newValue
            existing.absence.isAbsent = absence.isAbsent
            existing.expression.isExpression = expression.isExpression
            coalescedEdits[key] = existing
            return
        }
        coalescedEdits[key] = CoalescedCellEdit(
            rowID: rowID, columnIndex: columnIndex, columnName: columnName,
            previousValue: oldValue, newValue: newValue, originalRow: originalRow,
            absence: absence, expression: expression
        )
        coalescedOrder.append(key)
    }

    // A cell typed back to where it started is left out: undoing it would stage a value the server already holds.
    func endCoalescedUndoRun() {
        guard !coalescedOrder.isEmpty else {
            typingAction = nil
            return
        }
        let edits = coalescedOrder.compactMap { coalescedEdits[$0] }.filter { !$0.isNoOp }
        let action = typingAction
        discardCoalescedUndoRun()
        guard !edits.isEmpty, let undoManager = undoManagerProvider?() else { return }

        undoManager.beginUndoGrouping()
        for edit in edits {
            undoManager.registerUndo(withTarget: self) { target in
                target.applyDataUndo(
                    .cellEdit(
                        rowID: edit.rowID, columnIndex: edit.columnIndex, columnName: edit.columnName,
                        previousValue: edit.previousValue, newValue: edit.newValue, originalRow: edit.originalRow,
                        absence: edit.absence, expression: edit.expression
                    ),
                    actionID: action
                )
            }
        }
        undoManager.setActionName(String(localized: "Edit Cell"))
        undoManager.endUndoGrouping()
    }

    private func discardCoalescedUndoRun() {
        coalescedEdits.removeAll()
        coalescedOrder.removeAll()
        typingAction = nil
    }

    private func discardUndoHistory() {
        discardCoalescedUndoRun()
        loadedValues.removeAll()
        undoManagerProvider?()?.removeAllActions(withTarget: self)
    }

    // Kept beside the pending changes so a deletion an undo or redo records again gets them too.
    func adoptLoadedValues(_ values: [RowID: [Int: PluginCellValue]]) {
        for (rowID, cells) in values {
            loadedValues[rowID, default: [:]].merge(cells) { _, loaded in loaded }
        }
        objectWillChange.send()
        pending.adoptLoadedValues(values)
    }

    private func completedImage(_ row: [PluginCellValue], of rowID: RowID) -> [PluginCellValue] {
        guard let cells = loadedValues[rowID] else { return row }
        return RowChange.completing(row, with: cells)
    }

    func recordRowDeletion(rowID: RowID, originalRow: [PluginCellValue], absentColumns: Set<Int> = []) {
        let image = pending.imageAsRead(ofRow: rowID, current: originalRow, absentColumns: absentColumns)
        let rowAsRead = completedImage(image.row, of: rowID)
        let absentAsRead = image.absentColumns
        objectWillChange.send()
        pending.recordRowDeletion(rowID: rowID, originalRow: rowAsRead, absentColumns: absentAsRead)
        registerUndo(actionName: String(localized: "Delete Row")) { target in
            target.applyDataUndo(.rowDeletion(rowID: rowID, originalRow: rowAsRead, absentColumns: absentAsRead))
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
        var batchData: [(rowID: RowID, originalRow: [PluginCellValue])] = []
        var absentAsRead: [RowID: Set<Int>] = [:]
        batchData.reserveCapacity(rows.count)
        for row in rows {
            let image = pending.imageAsRead(
                ofRow: row.rowID, current: row.originalRow, absentColumns: absentColumns[row.rowID] ?? []
            )
            batchData.append((rowID: row.rowID, originalRow: completedImage(image.row, of: row.rowID)))
            if !image.absentColumns.isEmpty { absentAsRead[row.rowID] = image.absentColumns }
        }
        objectWillChange.send()
        for (rowID, originalRow) in batchData {
            pending.recordRowDeletion(
                rowID: rowID, originalRow: originalRow, absentColumns: absentAsRead[rowID] ?? []
            )
        }
        let deleted = batchData
        let deletedAbsentColumns = absentAsRead
        registerUndo(actionName: String(localized: "Delete Rows")) { target in
            target.applyDataUndo(.batchRowDeletion(rows: deleted, absentColumns: deletedAbsentColumns))
        }
        hasChanges = true
    }

    /// `expressionColumns` are cells of `values` staged as SQL, as a duplicate of a pending row carries them.
    func recordRowInsertion(
        rowID: RowID,
        values: [PluginCellValue],
        absentColumns: Set<Int> = [],
        expressionColumns: Set<Int> = []
    ) {
        objectWillChange.send()
        pending.recordRowInsertion(
            rowID: rowID, values: values, absentColumns: absentColumns, expressionColumns: expressionColumns
        )
        registerUndo(actionName: String(localized: "Insert Row")) { target in
            target.applyDataUndo(.rowInsertion(rowID: rowID))
        }
        hasChanges = true
    }

    struct InsertedRow {
        let location: InsertedRowLocation
        let values: [PluginCellValue]
        var absentColumns: Set<Int> = []
        var expressionColumns: Set<Int> = []
    }

    // One publish and one undo step for the whole batch, so a paste of many rows stays linear.
    func recordBatchRowInsertion(rows: [InsertedRow]) {
        guard rows.count > 1 else {
            if let row = rows.first {
                recordRowInsertion(
                    rowID: row.location.rowID, values: row.values,
                    absentColumns: row.absentColumns, expressionColumns: row.expressionColumns
                )
            }
            return
        }
        objectWillChange.send()
        for row in rows {
            pending.recordRowInsertion(
                rowID: row.location.rowID, values: row.values,
                absentColumns: row.absentColumns, expressionColumns: row.expressionColumns
            )
        }
        registerUndo(actionName: String(localized: "Insert Rows")) { target in
            target.applyDataUndo(.batchRowInsertion(
                rows: rows.map(\.location), rowValues: rows.map(\.values),
                rowAbsentColumns: rows.map(\.absentColumns), rowExpressionColumns: rows.map(\.expressionColumns)
            ))
        }
        hasChanges = true
    }

    // MARK: - Undo Operations

    func undoRowDeletion(rowID: RowID) {
        restoreDeletedRows([rowID])
    }

    // A step of its own, so Undo deletes the rows again rather than replaying the delete under it the wrong way round.
    func restoreDeletedRows(_ rowIDs: [RowID]) {
        let restored = rowIDs.compactMap { rowID -> (rowID: RowID, originalRow: [PluginCellValue], absent: Set<Int>)? in
            guard let delete = pending.change(forRow: rowID, type: .delete) else { return nil }
            return (rowID, completedImage(delete.originalRow ?? [], of: rowID), delete.absentColumns)
        }
        guard !restored.isEmpty else { return }
        objectWillChange.send()
        for row in restored {
            _ = pending.undoRowDeletion(rowID: row.rowID)
        }
        if restored.count == 1, let row = restored.first {
            registerUndo(actionName: Self.restoreRowActionName) { target in
                target.applyDataUndo(.rowDeletion(rowID: row.rowID, originalRow: row.originalRow, absentColumns: row.absent))
            }
        } else {
            let rows = restored.map { (rowID: $0.rowID, originalRow: $0.originalRow) }
            let absentColumns = Dictionary(
                restored.filter { !$0.absent.isEmpty }.map { ($0.rowID, $0.absent) },
                uniquingKeysWith: { first, _ in first }
            )
            registerUndo(actionName: Self.restoreRowsActionName) { target in
                target.applyDataUndo(.batchRowDeletion(rows: rows, absentColumns: absentColumns))
            }
        }
        hasChanges = !pending.isEmpty
    }

    private static var restoreRowActionName: String { String(localized: "Restore Row") }
    private static var restoreRowsActionName: String { String(localized: "Restore Rows") }

    // A delete and a restore replay through one step, which keeps the name of the command that made it.
    private func rowDeletionStepName(rowIsDeleted: Bool, batch: Bool) -> String {
        let isUndoing = undoManagerProvider?()?.isUndoing ?? false
        if isUndoing == rowIsDeleted {
            return batch ? String(localized: "Delete Rows") : String(localized: "Delete Row")
        }
        return batch ? Self.restoreRowsActionName : Self.restoreRowActionName
    }

    func undoBatchRowInsertion(rows: [InsertedRowLocation]) {
        let validRows = rows.filter { pending.isRowInserted($0.rowID) }
        guard !validRows.isEmpty else { return }
        let rowAbsentColumns = validRows.map { pending.insertedAbsentColumns(forRow: $0.rowID) }
        let rowExpressionColumns = validRows.map { pending.insertedExpressionColumns(forRow: $0.rowID) }
        objectWillChange.send()
        let rowValues = pending.undoBatchRowInsertion(
            rowIDs: validRows.map(\.rowID), columnCount: columns.count
        )
        registerUndo(actionName: String(localized: "Insert Rows")) { target in
            target.applyDataUndo(.batchRowInsertion(
                rows: validRows, rowValues: rowValues, rowAbsentColumns: rowAbsentColumns,
                rowExpressionColumns: rowExpressionColumns
            ))
        }
        hasChanges = !pending.isEmpty
    }

    // MARK: - Core Undo Application

    private func applyDataUndo(_ action: UndoAction, actionID: Int? = nil) {
        objectWillChange.send()
        switch action {
        case .cellEdit(let rowID, let columnIndex, let columnName, let previousValue, let newValue, let originalRow,
                       let absence, let expression):
            applyCellEditUndo(
                rowID: rowID, columnIndex: columnIndex, columnName: columnName,
                previousValue: previousValue, newValue: newValue, originalRow: originalRow,
                absence: absence, expression: expression, action: action, actionID: actionID
            )

        case .rowInsertion(let rowID, let image):
            applyRowInsertionUndo(rowID: rowID, restoring: image, action: action)

        case .rowDeletion(let rowID, let originalRow, let absentColumns):
            applyRowDeletionUndo(rowID: rowID, originalRow: originalRow, absentColumns: absentColumns, action: action)

        case .batchRowDeletion(let rows, let absentColumns):
            applyBatchRowDeletionUndo(rows: rows, absentColumns: absentColumns, action: action)

        case .batchRowInsertion(let rows, let rowValues, let rowAbsentColumns, let rowExpressionColumns):
            applyBatchRowInsertionUndo(
                rows: rows, rowValues: rowValues, rowAbsentColumns: rowAbsentColumns,
                rowExpressionColumns: rowExpressionColumns, action: action
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
        absence: FieldAbsence, expression: ExpressionTransition, action: UndoAction, actionID: Int?
    ) {
        let isUndoing = undoManagerProvider?()?.isUndoing ?? false
        registerUndo(actionName: String(localized: "Edit Cell")) { target in
            target.applyDataUndo(
                .cellEdit(
                    rowID: rowID, columnIndex: columnIndex, columnName: columnName,
                    previousValue: newValue, newValue: previousValue, originalRow: originalRow,
                    absence: absence.reversed, expression: expression.reversed
                ),
                actionID: actionID
            )
        }

        // A redo is a new write, so it goes back after the other rows' changes still pending, where it was.
        let updateHoldsCell = pending.change(forRow: rowID, type: .update)?
            .cellChanges.contains { $0.columnIndex == columnIndex } ?? false
        if updateHoldsCell, isUndoing {
            pending.revertCellWrite(
                rowID: rowID, columnIndex: columnIndex,
                columnName: columnName, previousValue: previousValue,
                previousIsAbsent: absence.wasAbsent,
                previousIsExpression: expression.wasExpression
            )
        } else if pending.change(forRow: rowID, type: .insert) != nil {
            pending.updateInsertedCellDirectly(
                rowID: rowID, columnIndex: columnIndex,
                columnName: columnName, newValue: previousValue,
                isAbsent: absence.wasAbsent, isExpression: expression.wasExpression
            )
        } else {
            pending.reapplyCellChange(
                rowID: rowID,
                columnIndex: columnIndex, columnName: columnName,
                originalDBValue: newValue, newValue: previousValue,
                originalRow: originalRow.map { completedImage($0, of: rowID) },
                absence: absence.reversed, expression: expression.reversed,
                action: actionID
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
                rowID: rowID, columns: columns, savedValues: image?.values, absentColumns: absentColumns,
                expressionColumns: image?.expressionColumns ?? []
            )
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: image?.values,
                restoreAbsentColumns: absentColumns
            )
            return
        }

        let removed = InsertedRowImage(
            values: pending.savedInsertedValues(forRow: rowID),
            absentColumns: pending.insertedAbsentColumns(forRow: rowID),
            expressionColumns: pending.insertedExpressionColumns(forRow: rowID)
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
        // The pending deletion's image, which a value loaded since the delete has completed.
        let image = completedImage(pending.change(forRow: rowID, type: .delete)?.originalRow ?? originalRow, of: rowID)
        let stepName = rowDeletionStepName(rowIsDeleted: pending.isRowDeleted(rowID), batch: false)
        registerUndo(actionName: stepName) { target in
            target.applyDataUndo(.rowDeletion(rowID: rowID, originalRow: image, absentColumns: absentColumns))
        }

        if pending.isRowDeleted(rowID) {
            _ = pending.undoRowDeletion(rowID: rowID)
            lastUndoResult = UndoResult(
                action: action, needsRowRemoval: false, needsRowRestore: true, restoreRow: originalRow,
                delta: .fullReplace
            )
        } else {
            pending.reapplyRowDeletion(rowID: rowID, originalRow: image, absentColumns: absentColumns)
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
        let images = rows.map { row in
            let image = pending.change(forRow: row.rowID, type: .delete)?.originalRow ?? row.originalRow
            return (rowID: row.rowID, originalRow: completedImage(image, of: row.rowID))
        }
        let stepName = rowDeletionStepName(rowIsDeleted: rows.contains { pending.isRowDeleted($0.rowID) }, batch: true)
        registerUndo(actionName: stepName) { target in
            target.applyDataUndo(.batchRowDeletion(rows: images, absentColumns: absentColumns))
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
            for (rowID, originalRow) in images {
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
        rows: [InsertedRowLocation],
        rowValues: [[PluginCellValue]],
        rowAbsentColumns: [Set<Int>],
        rowExpressionColumns: [Set<Int>],
        action: UndoAction
    ) {
        registerUndo(actionName: String(localized: "Insert Rows")) { target in
            target.applyDataUndo(.batchRowInsertion(
                rows: rows, rowValues: rowValues, rowAbsentColumns: rowAbsentColumns,
                rowExpressionColumns: rowExpressionColumns
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
                rowIDs: rowIDs, rowValues: rowValues, rowAbsentColumns: rowAbsentColumns,
                rowExpressionColumns: rowExpressionColumns, columns: columns
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
    func buildRowWrites(
        database: String,
        schema: String?,
        containsTableOperation: Bool,
        rowsWithUnloadedValues: Set<RowID> = [],
        writesThroughView: Bool = false,
        rowLocators: [RowID: String] = [:]
    ) throws -> RowWriteBuild {
        var factory = try statementFactory(rowLocators: rowLocators, database: database)
        factory.holdsKeyedWritesToOneRow = writesThroughView
        let operations = RowWriteOperationBuilder.operations(
            from: pending.changes,
            insertedRowData: pending.insertedRowData,
            deletedRowIDs: pending.deletedRowIDs,
            insertedRowIDs: pending.insertedRowIDs,
            target: DataWriteTarget(database: database, schema: schema, table: tableName),
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            generatedColumns: generatedColumns,
            containsTableOperation: containsTableOperation,
            rowsWithUnloadedValues: rowsWithUnloadedValues,
            writesThroughView: writesThroughView,
            rowLocators: rowLocators
        )

        let steps = try writeSteps(
            for: pending.changes,
            insertedRowData: pending.insertedRowData,
            deletedRowIDs: pending.deletedRowIDs,
            insertedRowIDs: pending.insertedRowIDs,
            factory: factory
        )
        return RowWriteBuild(steps: steps, operations: operations)
    }

    /// The statements for these changes, each held to the rows it should touch.
    func writeSteps(
        for changes: [RowChange],
        insertedRowData: [RowID: [PluginCellValue]] = [:],
        deletedRowIDs: Set<RowID> = [],
        insertedRowIDs: Set<RowID> = [],
        factory: RowChangeStatementFactory? = nil
    ) throws -> [DataWriteStep] {
        let statements = try (factory ?? statementFactory()).rowWriteStatements(
            for: changes,
            insertedRowData: insertedRowData,
            deletedRowIDs: deletedRowIDs,
            insertedRowIDs: insertedRowIDs
        )
        return DataWriteStep.rowWrites(statements, tableName: tableName, primaryKeyColumns: primaryKeyColumns)
    }

    func statementFactory(
        rowLocators: [RowID: String] = [:],
        database: String? = nil
    ) throws -> RowChangeStatementFactory {
        guard let databaseType else {
            throw DatabaseError.queryFailed("Cannot generate statements: table dialect not configured")
        }
        var factory = RowChangeStatementFactory(
            tableName: tableName,
            schemaName: schemaName,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            generatedColumns: generatedColumns,
            rowMatchPolicy: rowMatchPolicy,
            columnTypeNames: columnTypeNames,
            databaseType: databaseType,
            pluginDriver: pluginDriver
        )
        factory.rowLocators = rowLocators
        factory.database = database?.isEmpty == false ? database : nil
        return factory
    }

    // MARK: - Actions

    func getOriginalValues() -> [(rowID: RowID, columnIndex: Int, value: PluginCellValue, isAbsent: Bool)] {
        var originals: [(rowID: RowID, columnIndex: Int, value: PluginCellValue, isAbsent: Bool)] = []
        let updates = pending.changes.filter { $0.type == .update } + pending.supersededUpdates.values
        for change in updates {
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
        objectWillChange.send()
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
        rowMatchPolicy: RowMatchPolicy = .none,
        columnTypeNames: [String: String] = [:]
    ) {
        self.tableName = tableName
        self.schemaName = schemaName
        self.columns = state.columns
        self.primaryKeyColumns = state.primaryKeyColumns
        self.databaseType = databaseType
        self.generatedColumns = generatedColumns
        self.rowMatchPolicy = rowMatchPolicy
        self.columnTypeNames = columnTypeNames
        discardUndoHistory()
        objectWillChange.send()
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

    func pendingChange(forRow rowID: RowID) -> RowChange? {
        pending.firstChange(forRow: rowID)
    }

    func pendingUpdate(forRow rowID: RowID) -> RowChange? {
        pending.change(forRow: rowID, type: .update)
    }

    func isCellModified(rowID: RowID, columnIndex: Int) -> Bool {
        pending.isCellModified(rowID: rowID, columnIndex: columnIndex)
    }

    func getModifiedColumnsForRow(_ rowID: RowID) -> Set<Int> {
        pending.modifiedColumns(forRow: rowID)
    }

    func isExpression(rowID: RowID, columnIndex: Int) -> Bool {
        pending.isExpression(rowID: rowID, columnIndex: columnIndex)
    }

    /// The row's cells staged as SQL, which Copy as INSERT or UPDATE writes unquoted.
    func expressionColumns(forRow rowID: RowID) -> Set<Int> {
        pending.expressionColumns(forRow: rowID)
    }
}
