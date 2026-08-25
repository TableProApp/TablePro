//
//  StructureChangeManager.swift
//  TablePro
//
//  Manager for tracking structure/schema changes with O(1) lookups.
//  Mirrors DataChangeManager architecture for schema modifications.
//

import Foundation
import Observation
import TableProPluginKit

/// Manager for tracking and applying schema changes
@MainActor @Observable
final class StructureChangeManager: ChangeManaging {
    private(set) var pendingChanges: [SchemaChangeIdentifier: SchemaChange] = [:]
    @ObservationIgnored private var changeOrder: [SchemaChangeIdentifier] = []
    private(set) var validationErrors: [SchemaChangeIdentifier: String] = [:]
    var hasChanges: Bool { !pendingChanges.isEmpty }
    var reloadVersion: Int = 0

    // Current state (loaded from database)
    private(set) var currentColumns: [EditableColumnDefinition] = []
    private(set) var currentIndexes: [EditableIndexDefinition] = []
    private(set) var currentForeignKeys: [EditableForeignKeyDefinition] = []
    private(set) var currentPrimaryKey: [String] = []

    // Working state (includes uncommitted changes + placeholders)
    var workingColumns: [EditableColumnDefinition] = []
    var workingIndexes: [EditableIndexDefinition] = []
    var workingForeignKeys: [EditableForeignKeyDefinition] = []
    var workingPrimaryKey: [String] = []

    var tableName: String?

    // MARK: - Undo/Redo Support

    /// Private `NSUndoManager` owned by this change manager. Each
    /// `StructureChangeManager` instance has its own, so the registered actions
    /// can never outlive the manager (the UndoManager is freed when the manager
    /// is deallocated, taking its action queue with it). The app does not have
    /// an NSDocument-backed `NSWindow.undoManager`, and no view in the
    /// responder chain provides one, so wiring this through the window would
    /// silently no-op. Cmd+Z is routed by the app's own `.commands` block in
    /// `TableProApp` to `MainContentCommandActions.undoChange()`, which checks
    /// the active tab's `resultsViewMode` and calls into this manager directly.
    ///
    /// `groupsByEvent` is off. On it, NSUndoManager closes a group at the end of the run loop turn,
    /// which makes undo granularity a property of *timing* rather than of the operation: two
    /// separate user actions land in two groups only because a turn happened to pass between them,
    /// and a caller that performs several mutations in one turn silently gets a single undo whether
    /// it wanted one or not. Both behaviours are wanted here, so both are stated instead of
    /// inferred. `registerUndo` opens a group per mutation, and a caller that needs several
    /// mutations to undo as one wraps them in `performAsOneUndoStep`.
    private let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 100
        manager.groupsByEvent = false
        return manager
    }()

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    /// Mirrors `DataChangeManager.registerUndo`. The `groupingLevel` check is what lets
    /// `performAsOneUndoStep` nest: inside one, a group is already open and this adds to it rather
    /// than closing a group the batch still needs.
    private func registerUndo(_ actionName: String, _ handler: @escaping (StructureChangeManager) -> Void) {
        let opensOwnGroup = !undoManager.groupsByEvent && undoManager.groupingLevel == 0
        if opensOwnGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self, handler: handler)
        undoManager.setActionName(actionName)
        if opensOwnGroup { undoManager.endUndoGrouping() }
    }

    /// Runs `body` so everything it registers undoes as a single step. Deleting a multi-row
    /// selection is the case that needs it: the grid calls `deleteColumn` once per row, and one
    /// Cmd+Z should bring the whole selection back.
    func performAsOneUndoStep(_ body: () -> Void) {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        body()
    }

    // MARK: - Load Schema

    func loadSchema(
        tableName: String,
        columns: [ColumnInfo],
        indexes: [IndexInfo],
        foreignKeys: [ForeignKeyInfo],
        primaryKey: [String]
    ) {
        self.tableName = tableName

        self.currentColumns = columns.map { EditableColumnDefinition.from($0) }

        // Merge primary key info into columns (handles PostgreSQL where isPrimaryKey is always false)
        if !primaryKey.isEmpty {
            for i in currentColumns.indices {
                currentColumns[i].isPrimaryKey = primaryKey.contains(currentColumns[i].name)
            }
        }
        self.currentIndexes = indexes.map { EditableIndexDefinition.from($0) }
        // Group foreign keys by name to merge multi-column FKs into single definitions
        let groupedFKs = Dictionary(grouping: foreignKeys, by: { $0.name })
        self.currentForeignKeys = groupedFKs.keys.sorted().compactMap { name -> EditableForeignKeyDefinition? in
            guard let fkInfos = groupedFKs[name], let first = fkInfos.first else { return nil }
            return EditableForeignKeyDefinition(
                id: first.id,
                name: first.name,
                columns: fkInfos.map { $0.column },
                referencedTable: first.referencedTable,
                referencedColumns: fkInfos.map { $0.referencedColumn },
                referencedSchema: first.referencedSchema,
                onDelete: EditableForeignKeyDefinition.ReferentialAction(rawValue: first.onDelete.uppercased()) ?? .noAction,
                onUpdate: EditableForeignKeyDefinition.ReferentialAction(rawValue: first.onUpdate.uppercased()) ?? .noAction
            )
        }
        self.currentPrimaryKey = primaryKey

        resetWorkingState()

        pendingChanges.removeAll()
        changeOrder.removeAll()
        validationErrors.removeAll()
        undoManager.removeAllActions()

        // Increment reloadVersion to trigger DataGridView column width recalculation
        // This ensures columns auto-size based on actual cell content after initial load
        reloadVersion += 1
    }

    private func resetWorkingState() {
        workingColumns = currentColumns
        workingIndexes = currentIndexes
        workingForeignKeys = currentForeignKeys
        workingPrimaryKey = currentPrimaryKey
    }

    private func trackChangeKey(_ key: SchemaChangeIdentifier) {
        if !changeOrder.contains(key) {
            changeOrder.append(key)
        }
    }

    private func untrackChangeKey(_ key: SchemaChangeIdentifier) {
        changeOrder.removeAll { $0 == key }
    }

    // MARK: - Add New Rows

    func addNewColumn() {
        let placeholder = EditableColumnDefinition.placeholder()
        workingColumns.append(placeholder)
        let key = SchemaChangeIdentifier.column(placeholder.id)
        pendingChanges[key] = .addColumn(placeholder)
        trackChangeKey(key)
        registerUndo(String(localized: "Add Column")) { target in
            target.applySchemaUndo(.columnAdd(column: placeholder))
        }
        validate()
    }

    func addNewIndex() {
        let placeholder = EditableIndexDefinition.placeholder()
        workingIndexes.append(placeholder)
        let key = SchemaChangeIdentifier.index(placeholder.id)
        pendingChanges[key] = .addIndex(placeholder)
        trackChangeKey(key)
        registerUndo(String(localized: "Add Index")) { target in
            target.applySchemaUndo(.indexAdd(index: placeholder))
        }
        validate()
    }

    func addNewForeignKey() {
        let placeholder = EditableForeignKeyDefinition.placeholder()
        workingForeignKeys.append(placeholder)
        let key = SchemaChangeIdentifier.foreignKey(placeholder.id)
        pendingChanges[key] = .addForeignKey(placeholder)
        trackChangeKey(key)
        registerUndo(String(localized: "Add Foreign Key")) { target in
            target.applySchemaUndo(.foreignKeyAdd(fk: placeholder))
        }
        validate()
    }

    // MARK: - Paste Operations (public methods for adding copied items)

    func addColumn(_ column: EditableColumnDefinition) {
        workingColumns.append(column)
        let key = SchemaChangeIdentifier.column(column.id)
        pendingChanges[key] = .addColumn(column)
        trackChangeKey(key)
        registerUndo(String(localized: "Add Column")) { target in
            target.applySchemaUndo(.columnAdd(column: column))
        }
    }

    func addIndex(_ index: EditableIndexDefinition) {
        workingIndexes.append(index)
        let key = SchemaChangeIdentifier.index(index.id)
        pendingChanges[key] = .addIndex(index)
        trackChangeKey(key)
        registerUndo(String(localized: "Add Index")) { target in
            target.applySchemaUndo(.indexAdd(index: index))
        }
    }

    func addForeignKey(_ foreignKey: EditableForeignKeyDefinition) {
        workingForeignKeys.append(foreignKey)
        let key = SchemaChangeIdentifier.foreignKey(foreignKey.id)
        pendingChanges[key] = .addForeignKey(foreignKey)
        trackChangeKey(key)
        registerUndo(String(localized: "Add Foreign Key")) { target in
            target.applySchemaUndo(.foreignKeyAdd(fk: foreignKey))
        }
    }

    // MARK: - Column Operations

    func updateColumn(id: UUID, with newColumn: EditableColumnDefinition) {
        // Capture old working state for undo BEFORE modifying
        if let workingIndex = workingColumns.firstIndex(where: { $0.id == id }) {
            let oldWorking = workingColumns[workingIndex]
            if oldWorking != newColumn {
                registerUndo(String(localized: "Edit Column")) { target in
                    target.applySchemaUndo(.columnEdit(id: id, old: oldWorking, new: newColumn))
                }
            }
        }

        let key = SchemaChangeIdentifier.column(id)
        if let index = currentColumns.firstIndex(where: { $0.id == id }) {
            let oldColumn = currentColumns[index]
            if oldColumn != newColumn {
                pendingChanges[key] = .modifyColumn(old: oldColumn, new: newColumn)
                trackChangeKey(key)
            } else {
                pendingChanges.removeValue(forKey: key)
                untrackChangeKey(key)
            }
        } else {
            pendingChanges[key] = .addColumn(newColumn)
            trackChangeKey(key)
        }

        if let index = workingColumns.firstIndex(where: { $0.id == id }) {
            workingColumns[index] = newColumn
        }

        validate()
    }

    func deleteColumn(id: UUID) {
        let key = SchemaChangeIdentifier.column(id)
        if let column = currentColumns.first(where: { $0.id == id }) {
            registerUndo(String(localized: "Delete Column")) { target in
                target.applySchemaUndo(.columnDelete(column: column, at: nil))
            }
            pendingChanges[key] = .deleteColumn(column)
            trackChangeKey(key)
        } else {
            let rowIndex = workingColumns.firstIndex(where: { $0.id == id })
            if let column = workingColumns.first(where: { $0.id == id }) {
                registerUndo(String(localized: "Delete Column")) { target in
                    target.applySchemaUndo(.columnDelete(column: column, at: rowIndex))
                }
            }
            workingColumns.removeAll { $0.id == id }
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        }

        validate()
    }

    // MARK: - Index Operations

    func updateIndex(id: UUID, with newIndex: EditableIndexDefinition) {
        // Capture old working state for undo BEFORE modifying
        if let workingIdx = workingIndexes.firstIndex(where: { $0.id == id }) {
            let oldWorking = workingIndexes[workingIdx]
            if oldWorking != newIndex {
                registerUndo(String(localized: "Edit Index")) { target in
                    target.applySchemaUndo(.indexEdit(id: id, old: oldWorking, new: newIndex))
                }
            }
        }

        let key = SchemaChangeIdentifier.index(id)
        if let index = currentIndexes.firstIndex(where: { $0.id == id }) {
            let oldIndex = currentIndexes[index]
            if oldIndex != newIndex {
                pendingChanges[key] = .modifyIndex(old: oldIndex, new: newIndex)
                trackChangeKey(key)
            } else {
                pendingChanges.removeValue(forKey: key)
                untrackChangeKey(key)
            }
        } else {
            pendingChanges[key] = .addIndex(newIndex)
            trackChangeKey(key)
        }

        if let index = workingIndexes.firstIndex(where: { $0.id == id }) {
            workingIndexes[index] = newIndex
        }

        validate()
    }

    func deleteIndex(id: UUID) {
        let key = SchemaChangeIdentifier.index(id)
        if let index = currentIndexes.first(where: { $0.id == id }) {
            registerUndo(String(localized: "Delete Index")) { target in
                target.applySchemaUndo(.indexDelete(index: index, at: nil))
            }
            pendingChanges[key] = .deleteIndex(index)
            trackChangeKey(key)
        } else {
            let rowIndex = workingIndexes.firstIndex(where: { $0.id == id })
            if let index = workingIndexes.first(where: { $0.id == id }) {
                registerUndo(String(localized: "Delete Index")) { target in
                    target.applySchemaUndo(.indexDelete(index: index, at: rowIndex))
                }
            }
            workingIndexes.removeAll { $0.id == id }
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        }

        validate()
    }

    // MARK: - Foreign Key Operations

    func updateForeignKey(id: UUID, with newFK: EditableForeignKeyDefinition) {
        // Capture old working state for undo BEFORE modifying
        if let workingIdx = workingForeignKeys.firstIndex(where: { $0.id == id }) {
            let oldWorking = workingForeignKeys[workingIdx]
            if oldWorking != newFK {
                registerUndo(String(localized: "Edit Foreign Key")) { target in
                    target.applySchemaUndo(.foreignKeyEdit(id: id, old: oldWorking, new: newFK))
                }
            }
        }

        let key = SchemaChangeIdentifier.foreignKey(id)
        if let index = currentForeignKeys.firstIndex(where: { $0.id == id }) {
            let oldFK = currentForeignKeys[index]
            if oldFK != newFK {
                pendingChanges[key] = .modifyForeignKey(old: oldFK, new: newFK)
                trackChangeKey(key)
            } else {
                pendingChanges.removeValue(forKey: key)
                untrackChangeKey(key)
            }
        } else {
            pendingChanges[key] = .addForeignKey(newFK)
            trackChangeKey(key)
        }

        if let index = workingForeignKeys.firstIndex(where: { $0.id == id }) {
            workingForeignKeys[index] = newFK
        }

        validate()
    }

    func deleteForeignKey(id: UUID) {
        let key = SchemaChangeIdentifier.foreignKey(id)
        if let fk = currentForeignKeys.first(where: { $0.id == id }) {
            registerUndo(String(localized: "Delete Foreign Key")) { target in
                target.applySchemaUndo(.foreignKeyDelete(fk: fk, at: nil))
            }
            pendingChanges[key] = .deleteForeignKey(fk)
            trackChangeKey(key)
        } else {
            let rowIndex = workingForeignKeys.firstIndex(where: { $0.id == id })
            if let fk = workingForeignKeys.first(where: { $0.id == id }) {
                registerUndo(String(localized: "Delete Foreign Key")) { target in
                    target.applySchemaUndo(.foreignKeyDelete(fk: fk, at: rowIndex))
                }
            }
            workingForeignKeys.removeAll { $0.id == id }
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        }

        validate()
    }

    // MARK: - Row-Specific Undo Delete

    /// Clear the deletion mark for the entity at `row` in `tab`. Mirrors
    /// `DataChangeManager.undoRowDeletion(rowIndex:)`: the global NSUndoManager
    /// stack is intentionally left alone. The original `applySchemaUndo(...)`
    /// handler the deletion registered remains on the stack; if global Cmd+Z
    /// later invokes it, the handler finds `pendingChanges` no longer marks
    /// this row as deleted and treats the redo as a no-op for this entity. The
    /// row-specific affordance and the global undo stack are independent
    /// affordances. The data tab uses the same separation.
    func undoDelete(for tab: StructureTab, at row: Int) {
        let key: SchemaChangeIdentifier
        switch tab {
        case .columns:
            guard row < workingColumns.count else { return }
            key = .column(workingColumns[row].id)
        case .indexes:
            guard row < workingIndexes.count else { return }
            key = .index(workingIndexes[row].id)
        case .foreignKeys:
            guard row < workingForeignKeys.count else { return }
            key = .foreignKey(workingForeignKeys[row].id)
        case .ddl, .parts, .triggers:
            return
        }
        guard pendingChanges[key]?.isDelete == true else { return }
        pendingChanges.removeValue(forKey: key)
        untrackChangeKey(key)
        validate()
    }

    // MARK: - Validation

    private func validate() {
        validationErrors.removeAll()

        for column in workingColumns {
            if !column.isValid {
                validationErrors[.column(column.id)] = "Column must have a name and data type"
            }
        }

        let columnNames = workingColumns.filter { column in
            column.isValid && !isColumnPendingDeletion(column.id)
        }.map { $0.name }
        let duplicateColumns = Dictionary(grouping: columnNames, by: { $0 })
            .filter { $0.value.count > 1 }
            .map { $0.key }

        for duplicate in duplicateColumns {
            for column in workingColumns.filter({ $0.name == duplicate && !isColumnPendingDeletion($0.id) }) {
                validationErrors[.column(column.id)] = "Duplicate column name: \(duplicate)"
            }
        }

        for index in workingIndexes {
            if !index.isValid {
                validationErrors[.index(index.id)] = "Index must have a name and at least one column"
            }
        }

        for fk in workingForeignKeys {
            if !fk.isValid {
                validationErrors[.foreignKey(fk.id)] = "Foreign key must have name, columns, and referenced table"
            }
        }

        let indexNames = workingIndexes.filter { $0.isValid }.map { $0.name }
        let duplicateIndexes = Dictionary(grouping: indexNames, by: { $0 })
            .filter { $0.value.count > 1 }
            .map { $0.key }

        for duplicate in duplicateIndexes {
            for index in workingIndexes.filter({ $0.name == duplicate }) {
                validationErrors[.index(index.id)] = "Duplicate index name: \(duplicate)"
            }
        }

        for index in workingIndexes.filter({ $0.isValid }) {
            for columnName in index.columns {
                if !columnNames.contains(columnName) {
                    validationErrors[.index(index.id)] = "Index references non-existent column: \(columnName)"
                }
            }
        }

        for fk in workingForeignKeys.filter({ $0.isValid }) {
            for columnName in fk.columns {
                if !columnNames.contains(columnName) {
                    validationErrors[.foreignKey(fk.id)] = "Foreign key references non-existent column: \(columnName)"
                }
            }
        }

        for columnName in workingPrimaryKey {
            if !columnNames.contains(columnName) {
                validationErrors[.primaryKey] = "Primary key references non-existent column: \(columnName)"
            }
        }
    }

    private func isColumnPendingDeletion(_ id: UUID) -> Bool {
        if case .deleteColumn = pendingChanges[.column(id)] {
            return true
        }
        return false
    }

    // MARK: - State Management

    var canCommit: Bool {
        hasChanges && validationErrors.isEmpty
    }

    func discardChanges() {
        pendingChanges.removeAll()
        changeOrder.removeAll()
        validationErrors.removeAll()
        resetWorkingState()
        reloadVersion += 1
        undoManager.removeAllActions()
    }

    func getChangesArray() -> [SchemaChange] {
        changeOrder.compactMap { pendingChanges[$0] }
    }

    // MARK: - Undo/Redo Operations

    func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
    }

    func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
    }

    private func applySchemaUndo(_ action: SchemaUndoAction) {
        switch action {
        case .columnEdit(let id, let old, let new):
            applyColumnEditUndo(id: id, old: old, new: new)
        case .columnAdd(let column):
            applyColumnAddUndo(column: column)
        case .columnDelete(let column, let at):
            applyColumnDeleteUndo(column: column, at: at)
        case .indexEdit(let id, let old, let new):
            applyIndexEditUndo(id: id, old: old, new: new)
        case .indexAdd(let index):
            applyIndexAddUndo(index: index)
        case .indexDelete(let index, let at):
            applyIndexDeleteUndo(index: index, at: at)
        case .foreignKeyEdit(let id, let old, let new):
            applyForeignKeyEditUndo(id: id, old: old, new: new)
        case .foreignKeyAdd(let fk):
            applyForeignKeyAddUndo(fk: fk)
        case .foreignKeyDelete(let fk, let at):
            applyForeignKeyDeleteUndo(fk: fk, at: at)
        case .primaryKeyChange(let old, _):
            applyPrimaryKeyChangeUndo(old: old)
        }

        validate()
    }

    private func applyColumnEditUndo(id: UUID, old: EditableColumnDefinition, new: EditableColumnDefinition) {
        registerUndo(String(localized: "Edit Column")) { target in
            target.applySchemaUndo(.columnEdit(id: id, old: new, new: old))
        }
        let colKey = SchemaChangeIdentifier.column(id)
        if let index = workingColumns.firstIndex(where: { $0.id == id }) {
            workingColumns[index] = old
            if let currentIndex = currentColumns.firstIndex(where: { $0.id == id }) {
                let current = currentColumns[currentIndex]
                if old != current {
                    pendingChanges[colKey] = .modifyColumn(old: current, new: old)
                    trackChangeKey(colKey)
                } else {
                    pendingChanges.removeValue(forKey: colKey)
                    untrackChangeKey(colKey)
                }
            } else {
                pendingChanges[colKey] = .addColumn(old)
                trackChangeKey(colKey)
            }
        }
    }

    private func applyColumnAddUndo(column: EditableColumnDefinition) {
        let removedIndex = workingColumns.firstIndex(where: { $0.id == column.id })
        registerUndo(String(localized: "Add Column")) { target in
            target.applySchemaUndo(.columnDelete(column: column, at: removedIndex))
        }
        let addColKey = SchemaChangeIdentifier.column(column.id)
        if currentColumns.contains(where: { $0.id == column.id }) {
            pendingChanges[addColKey] = .deleteColumn(column)
            trackChangeKey(addColKey)
        } else {
            workingColumns.removeAll { $0.id == column.id }
            pendingChanges.removeValue(forKey: addColKey)
            untrackChangeKey(addColKey)
        }
    }

    private func applyColumnDeleteUndo(column: EditableColumnDefinition, at: Int?) {
        registerUndo(String(localized: "Delete Column")) { target in
            target.applySchemaUndo(.columnAdd(column: column))
        }
        let delColKey = SchemaChangeIdentifier.column(column.id)
        if currentColumns.contains(where: { $0.id == column.id }) {
            pendingChanges.removeValue(forKey: delColKey)
            untrackChangeKey(delColKey)
        } else {
            if let at, at < workingColumns.count {
                workingColumns.insert(column, at: at)
            } else {
                workingColumns.append(column)
            }
            pendingChanges[delColKey] = .addColumn(column)
            trackChangeKey(delColKey)
        }
    }

    private func applyIndexEditUndo(id: UUID, old: EditableIndexDefinition, new: EditableIndexDefinition) {
        registerUndo(String(localized: "Edit Index")) { target in
            target.applySchemaUndo(.indexEdit(id: id, old: new, new: old))
        }
        let idxEditKey = SchemaChangeIdentifier.index(id)
        if let idx = workingIndexes.firstIndex(where: { $0.id == id }) {
            workingIndexes[idx] = old
            if let currentIdx = currentIndexes.firstIndex(where: { $0.id == id }) {
                let current = currentIndexes[currentIdx]
                if old != current {
                    pendingChanges[idxEditKey] = .modifyIndex(old: current, new: old)
                    trackChangeKey(idxEditKey)
                } else {
                    pendingChanges.removeValue(forKey: idxEditKey)
                    untrackChangeKey(idxEditKey)
                }
            } else {
                pendingChanges[idxEditKey] = .addIndex(old)
                trackChangeKey(idxEditKey)
            }
        }
    }

    private func applyIndexAddUndo(index: EditableIndexDefinition) {
        let removedIndex = workingIndexes.firstIndex(where: { $0.id == index.id })
        registerUndo(String(localized: "Add Index")) { target in
            target.applySchemaUndo(.indexDelete(index: index, at: removedIndex))
        }
        let idxAddKey = SchemaChangeIdentifier.index(index.id)
        if currentIndexes.contains(where: { $0.id == index.id }) {
            pendingChanges[idxAddKey] = .deleteIndex(index)
            trackChangeKey(idxAddKey)
        } else {
            workingIndexes.removeAll { $0.id == index.id }
            pendingChanges.removeValue(forKey: idxAddKey)
            untrackChangeKey(idxAddKey)
        }
    }

    private func applyIndexDeleteUndo(index: EditableIndexDefinition, at: Int?) {
        registerUndo(String(localized: "Delete Index")) { target in
            target.applySchemaUndo(.indexAdd(index: index))
        }
        let idxDelKey = SchemaChangeIdentifier.index(index.id)
        if currentIndexes.contains(where: { $0.id == index.id }) {
            pendingChanges.removeValue(forKey: idxDelKey)
            untrackChangeKey(idxDelKey)
        } else {
            if let at, at < workingIndexes.count {
                workingIndexes.insert(index, at: at)
            } else {
                workingIndexes.append(index)
            }
            pendingChanges[idxDelKey] = .addIndex(index)
            trackChangeKey(idxDelKey)
        }
    }

    private func applyForeignKeyEditUndo(
        id: UUID,
        old: EditableForeignKeyDefinition,
        new: EditableForeignKeyDefinition
    ) {
        registerUndo(String(localized: "Edit Foreign Key")) { target in
            target.applySchemaUndo(.foreignKeyEdit(id: id, old: new, new: old))
        }
        let fkEditKey = SchemaChangeIdentifier.foreignKey(id)
        if let idx = workingForeignKeys.firstIndex(where: { $0.id == id }) {
            workingForeignKeys[idx] = old
            if let currentIdx = currentForeignKeys.firstIndex(where: { $0.id == id }) {
                let current = currentForeignKeys[currentIdx]
                if old != current {
                    pendingChanges[fkEditKey] = .modifyForeignKey(old: current, new: old)
                    trackChangeKey(fkEditKey)
                } else {
                    pendingChanges.removeValue(forKey: fkEditKey)
                    untrackChangeKey(fkEditKey)
                }
            } else {
                pendingChanges[fkEditKey] = .addForeignKey(old)
                trackChangeKey(fkEditKey)
            }
        }
    }

    private func applyForeignKeyAddUndo(fk: EditableForeignKeyDefinition) {
        let removedIndex = workingForeignKeys.firstIndex(where: { $0.id == fk.id })
        registerUndo(String(localized: "Add Foreign Key")) { target in
            target.applySchemaUndo(.foreignKeyDelete(fk: fk, at: removedIndex))
        }
        let fkAddKey = SchemaChangeIdentifier.foreignKey(fk.id)
        if currentForeignKeys.contains(where: { $0.id == fk.id }) {
            pendingChanges[fkAddKey] = .deleteForeignKey(fk)
            trackChangeKey(fkAddKey)
        } else {
            workingForeignKeys.removeAll { $0.id == fk.id }
            pendingChanges.removeValue(forKey: fkAddKey)
            untrackChangeKey(fkAddKey)
        }
    }

    private func applyForeignKeyDeleteUndo(fk: EditableForeignKeyDefinition, at: Int?) {
        registerUndo(String(localized: "Delete Foreign Key")) { target in
            target.applySchemaUndo(.foreignKeyAdd(fk: fk))
        }
        let fkDelKey = SchemaChangeIdentifier.foreignKey(fk.id)
        if currentForeignKeys.contains(where: { $0.id == fk.id }) {
            pendingChanges.removeValue(forKey: fkDelKey)
            untrackChangeKey(fkDelKey)
        } else {
            if let at, at < workingForeignKeys.count {
                workingForeignKeys.insert(fk, at: at)
            } else {
                workingForeignKeys.append(fk)
            }
            pendingChanges[fkDelKey] = .addForeignKey(fk)
            trackChangeKey(fkDelKey)
        }
    }

    private func applyPrimaryKeyChangeUndo(old: [String]) {
        let current = workingPrimaryKey
        registerUndo(String(localized: "Change Primary Key")) { target in
            target.applySchemaUndo(.primaryKeyChange(old: current, new: old))
        }
        workingPrimaryKey = old
        let pkKey = SchemaChangeIdentifier.primaryKey
        if workingPrimaryKey != currentPrimaryKey {
            pendingChanges[pkKey] = .modifyPrimaryKey(old: currentPrimaryKey, new: workingPrimaryKey)
            trackChangeKey(pkKey)
        } else {
            pendingChanges.removeValue(forKey: pkKey)
            untrackChangeKey(pkKey)
        }
    }

    // MARK: - Visual State Management

    /// Per-row delete/insert flags. Modified-column tinting is computed by the
    /// `StructureGridDelegate` because it requires the tab's `orderedFields`
    /// (which depends on the database type and is a UI concern). The delegate
    /// merges the result of this method with `modifiedColumns` from
    /// `StructureEditingSupport` field-diff helpers to build the final
    /// `RowVisualState`.
    func deleteInsertState(for row: Int, tab: StructureTab) -> (isDeleted: Bool, isInserted: Bool) {
        switch tab {
        case .columns:
            guard row < workingColumns.count else { return (false, false) }
            let column = workingColumns[row]
            let change = pendingChanges[.column(column.id)]
            let isDeleted = change?.isDelete ?? false
            let isInserted = !currentColumns.contains(where: { $0.id == column.id })
            return (isDeleted, isInserted)
        case .indexes:
            guard row < workingIndexes.count else { return (false, false) }
            let index = workingIndexes[row]
            let change = pendingChanges[.index(index.id)]
            let isDeleted = change?.isDelete ?? false
            let isInserted = !currentIndexes.contains(where: { $0.id == index.id })
            return (isDeleted, isInserted)
        case .foreignKeys:
            guard row < workingForeignKeys.count else { return (false, false) }
            let fk = workingForeignKeys[row]
            let change = pendingChanges[.foreignKey(fk.id)]
            let isDeleted = change?.isDelete ?? false
            let isInserted = !currentForeignKeys.contains(where: { $0.id == fk.id })
            return (isDeleted, isInserted)
        case .ddl, .parts, .triggers:
            return (false, false)
        }
    }

    // MARK: - ChangeManaging Conformance (Data-Specific No-Ops)

    var rowChanges: [RowChange] { [] }

    var insertedRowIndices: Set<Int> { [] }

    func isRowDeleted(_ rowIndex: Int) -> Bool { false }

    func recordCellChange(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?
    ) {}

    func undoRowDeletion(rowIndex: Int) {}

    func undoRowInsertion(rowIndex: Int) {}
}

// MARK: - Schema Undo Action

enum SchemaUndoAction {
    case columnEdit(id: UUID, old: EditableColumnDefinition, new: EditableColumnDefinition)
    case columnAdd(column: EditableColumnDefinition)
    case columnDelete(column: EditableColumnDefinition, at: Int?)
    case indexEdit(id: UUID, old: EditableIndexDefinition, new: EditableIndexDefinition)
    case indexAdd(index: EditableIndexDefinition)
    case indexDelete(index: EditableIndexDefinition, at: Int?)
    case foreignKeyEdit(id: UUID, old: EditableForeignKeyDefinition, new: EditableForeignKeyDefinition)
    case foreignKeyAdd(fk: EditableForeignKeyDefinition)
    case foreignKeyDelete(fk: EditableForeignKeyDefinition, at: Int?)
    case primaryKeyChange(old: [String], new: [String])
}
