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
    private(set) var currentCheckConstraints: [EditableCheckConstraintDefinition] = []
    private(set) var currentPrimaryKey: [String] = []

    // Working state (includes uncommitted changes + placeholders)
    var workingColumns: [EditableColumnDefinition] = []
    var workingIndexes: [EditableIndexDefinition] = []
    var workingForeignKeys: [EditableForeignKeyDefinition] = []
    var workingCheckConstraints: [EditableCheckConstraintDefinition] = []
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
        checkConstraints: [CheckConstraintInfo] = [],
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
        self.currentCheckConstraints = checkConstraints.map { EditableCheckConstraintDefinition.from($0) }
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
        workingCheckConstraints = currentCheckConstraints
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
        stageAddition(EditableColumnDefinition.placeholder(), using: Self.columnOperations, revalidating: true)
    }

    func addNewIndex() {
        stageAddition(EditableIndexDefinition.placeholder(), using: Self.indexOperations, revalidating: true)
    }

    func addNewForeignKey() {
        stageAddition(EditableForeignKeyDefinition.placeholder(), using: Self.foreignKeyOperations, revalidating: true)
    }

    func addNewCheckConstraint() {
        stageAddition(
            EditableCheckConstraintDefinition.placeholder(), using: Self.checkConstraintOperations, revalidating: true
        )
    }

    // MARK: - Paste Operations (public methods for adding copied items)

    func addColumn(_ column: EditableColumnDefinition) {
        stageAddition(column, using: Self.columnOperations, revalidating: false)
    }

    func addIndex(_ index: EditableIndexDefinition) {
        stageAddition(index, using: Self.indexOperations, revalidating: false)
    }

    func addForeignKey(_ foreignKey: EditableForeignKeyDefinition) {
        stageAddition(foreignKey, using: Self.foreignKeyOperations, revalidating: false)
    }

    func addCheckConstraint(_ constraint: EditableCheckConstraintDefinition) {
        stageAddition(constraint, using: Self.checkConstraintOperations, revalidating: false)
    }

    // MARK: - Column Operations

    func updateColumn(id: UUID, with newColumn: EditableColumnDefinition) {
        stageEdit(id: id, with: newColumn, using: Self.columnOperations)
    }

    func deleteColumn(id: UUID) {
        stageDeletion(id: id, using: Self.columnOperations)
    }

    // MARK: - Index Operations

    func updateIndex(id: UUID, with newIndex: EditableIndexDefinition) {
        stageEdit(id: id, with: newIndex, using: Self.indexOperations)
    }

    func deleteIndex(id: UUID) {
        stageDeletion(id: id, using: Self.indexOperations)
    }

    // MARK: - Foreign Key Operations

    func updateForeignKey(id: UUID, with newFK: EditableForeignKeyDefinition) {
        stageEdit(id: id, with: newFK, using: Self.foreignKeyOperations)
    }

    func deleteForeignKey(id: UUID) {
        stageDeletion(id: id, using: Self.foreignKeyOperations)
    }

    // MARK: - Check Constraint Operations

    func updateCheckConstraint(id: UUID, with newConstraint: EditableCheckConstraintDefinition) {
        stageEdit(id: id, with: newConstraint, using: Self.checkConstraintOperations)
    }

    func deleteCheckConstraint(id: UUID) {
        stageDeletion(id: id, using: Self.checkConstraintOperations)
    }

    // MARK: - Generic Staging

    /// The four entity kinds stage identically, so the sequence lives here once and each kind
    /// supplies only what differs. Before this existed the block below was written out per kind,
    /// which is how `charset`/`collation` came to be dropped in one copy and not the others: a
    /// fix applied to one hand-written copy has no way to reach its three siblings.
    private func stageAddition<Entity>(
        _ entity: Entity,
        using operations: SchemaEntityOperations<Entity>,
        revalidating: Bool
    ) {
        self[keyPath: operations.working].append(entity)
        let key = operations.identifier(entity.id)
        pendingChanges[key] = operations.addition(entity)
        trackChangeKey(key)
        registerUndo(operations.addActionName) { target in
            target.applySchemaUndo(operations.additionUndo(entity))
        }
        if revalidating { validate() }
    }

    private func stageEdit<Entity>(
        id: UUID,
        with newEntity: Entity,
        using operations: SchemaEntityOperations<Entity>
    ) {
        if let workingIndex = self[keyPath: operations.working].firstIndex(where: { $0.id == id }) {
            let oldWorking = self[keyPath: operations.working][workingIndex]
            if oldWorking != newEntity {
                registerUndo(operations.editActionName) { target in
                    target.applySchemaUndo(operations.editUndo(id, oldWorking, newEntity))
                }
            }
        }

        let key = operations.identifier(id)
        if let currentIndex = self[keyPath: operations.current].firstIndex(where: { $0.id == id }) {
            let oldEntity = self[keyPath: operations.current][currentIndex]
            if oldEntity != newEntity {
                pendingChanges[key] = operations.modification(oldEntity, newEntity)
                trackChangeKey(key)
            } else {
                pendingChanges.removeValue(forKey: key)
                untrackChangeKey(key)
            }
        } else {
            pendingChanges[key] = operations.addition(newEntity)
            trackChangeKey(key)
        }

        if let workingIndex = self[keyPath: operations.working].firstIndex(where: { $0.id == id }) {
            self[keyPath: operations.working][workingIndex] = newEntity
        }

        validate()
    }

    private func stageDeletion<Entity>(id: UUID, using operations: SchemaEntityOperations<Entity>) {
        let key = operations.identifier(id)
        if let entity = self[keyPath: operations.current].first(where: { $0.id == id }) {
            registerUndo(operations.deleteActionName) { target in
                target.applySchemaUndo(operations.deletionUndo(entity, nil))
            }
            pendingChanges[key] = operations.deletion(entity)
            trackChangeKey(key)
        } else {
            let rowIndex = self[keyPath: operations.working].firstIndex(where: { $0.id == id })
            if let entity = self[keyPath: operations.working].first(where: { $0.id == id }) {
                registerUndo(operations.deleteActionName) { target in
                    target.applySchemaUndo(operations.deletionUndo(entity, rowIndex))
                }
            }
            self[keyPath: operations.working].removeAll { $0.id == id }
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        }

        validate()
    }

    private static let columnOperations = SchemaEntityOperations<EditableColumnDefinition>(
        working: \.workingColumns,
        current: \.currentColumns,
        identifier: SchemaChangeIdentifier.column,
        addition: SchemaChange.addColumn,
        modification: { SchemaChange.modifyColumn(old: $0, new: $1) },
        deletion: SchemaChange.deleteColumn,
        additionUndo: { SchemaUndoAction.columnAdd(column: $0) },
        editUndo: { SchemaUndoAction.columnEdit(id: $0, old: $1, new: $2) },
        deletionUndo: { SchemaUndoAction.columnDelete(column: $0, at: $1) },
        addActionName: String(localized: "Add Column"),
        editActionName: String(localized: "Edit Column"),
        deleteActionName: String(localized: "Delete Column")
    )

    private static let indexOperations = SchemaEntityOperations<EditableIndexDefinition>(
        working: \.workingIndexes,
        current: \.currentIndexes,
        identifier: SchemaChangeIdentifier.index,
        addition: SchemaChange.addIndex,
        modification: { SchemaChange.modifyIndex(old: $0, new: $1) },
        deletion: SchemaChange.deleteIndex,
        additionUndo: { SchemaUndoAction.indexAdd(index: $0) },
        editUndo: { SchemaUndoAction.indexEdit(id: $0, old: $1, new: $2) },
        deletionUndo: { SchemaUndoAction.indexDelete(index: $0, at: $1) },
        addActionName: String(localized: "Add Index"),
        editActionName: String(localized: "Edit Index"),
        deleteActionName: String(localized: "Delete Index")
    )

    private static let foreignKeyOperations = SchemaEntityOperations<EditableForeignKeyDefinition>(
        working: \.workingForeignKeys,
        current: \.currentForeignKeys,
        identifier: SchemaChangeIdentifier.foreignKey,
        addition: SchemaChange.addForeignKey,
        modification: { SchemaChange.modifyForeignKey(old: $0, new: $1) },
        deletion: SchemaChange.deleteForeignKey,
        additionUndo: { SchemaUndoAction.foreignKeyAdd(fk: $0) },
        editUndo: { SchemaUndoAction.foreignKeyEdit(id: $0, old: $1, new: $2) },
        deletionUndo: { SchemaUndoAction.foreignKeyDelete(fk: $0, at: $1) },
        addActionName: String(localized: "Add Foreign Key"),
        editActionName: String(localized: "Edit Foreign Key"),
        deleteActionName: String(localized: "Delete Foreign Key")
    )

    private static let checkConstraintOperations = SchemaEntityOperations<EditableCheckConstraintDefinition>(
        working: \.workingCheckConstraints,
        current: \.currentCheckConstraints,
        identifier: SchemaChangeIdentifier.checkConstraint,
        addition: SchemaChange.addCheckConstraint,
        modification: { SchemaChange.modifyCheckConstraint(old: $0, new: $1) },
        deletion: SchemaChange.deleteCheckConstraint,
        additionUndo: { SchemaUndoAction.checkConstraintAdd(constraint: $0) },
        editUndo: { SchemaUndoAction.checkConstraintEdit(id: $0, old: $1, new: $2) },
        deletionUndo: { SchemaUndoAction.checkConstraintDelete(constraint: $0, at: $1) },
        addActionName: String(localized: "Add Check Constraint"),
        editActionName: String(localized: "Edit Check Constraint"),
        deleteActionName: String(localized: "Delete Check Constraint")
    )


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
        case .checkConstraints:
            guard row < workingCheckConstraints.count else { return }
            key = .checkConstraint(workingCheckConstraints[row].id)
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

        for constraint in workingCheckConstraints where !constraint.isValid {
            validationErrors[.checkConstraint(constraint.id)] =
                "Check constraint must have a name and an expression"
        }

        let constraintNames = workingCheckConstraints.filter { $0.isValid }.map { $0.name }
        let duplicateConstraints = Dictionary(grouping: constraintNames, by: { $0 })
            .filter { $0.value.count > 1 }
            .map { $0.key }

        for duplicate in duplicateConstraints {
            for constraint in workingCheckConstraints.filter({ $0.name == duplicate }) {
                validationErrors[.checkConstraint(constraint.id)] = "Duplicate constraint name: \(duplicate)"
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
            applyEditUndo(id: id, old: old, new: new, using: Self.columnOperations)
        case .columnAdd(let column):
            applyAdditionUndo(column, using: Self.columnOperations)
        case .columnDelete(let column, let at):
            applyDeletionUndo(column, at: at, using: Self.columnOperations)
        case .indexEdit(let id, let old, let new):
            applyEditUndo(id: id, old: old, new: new, using: Self.indexOperations)
        case .indexAdd(let index):
            applyAdditionUndo(index, using: Self.indexOperations)
        case .indexDelete(let index, let at):
            applyDeletionUndo(index, at: at, using: Self.indexOperations)
        case .foreignKeyEdit(let id, let old, let new):
            applyEditUndo(id: id, old: old, new: new, using: Self.foreignKeyOperations)
        case .foreignKeyAdd(let fk):
            applyAdditionUndo(fk, using: Self.foreignKeyOperations)
        case .foreignKeyDelete(let fk, let at):
            applyDeletionUndo(fk, at: at, using: Self.foreignKeyOperations)
        case .checkConstraintEdit(let id, let old, let new):
            applyEditUndo(id: id, old: old, new: new, using: Self.checkConstraintOperations)
        case .checkConstraintAdd(let constraint):
            applyAdditionUndo(constraint, using: Self.checkConstraintOperations)
        case .checkConstraintDelete(let constraint, let at):
            applyDeletionUndo(constraint, at: at, using: Self.checkConstraintOperations)
        case .primaryKeyChange(let old, _):
            applyPrimaryKeyChangeUndo(old: old)
        }

        validate()
    }

    private func applyEditUndo<Entity>(
        id: UUID,
        old: Entity,
        new: Entity,
        using operations: SchemaEntityOperations<Entity>
    ) {
        registerUndo(operations.editActionName) { target in
            target.applySchemaUndo(operations.editUndo(id, new, old))
        }
        let key = operations.identifier(id)
        guard let workingIndex = self[keyPath: operations.working].firstIndex(where: { $0.id == id }) else { return }
        self[keyPath: operations.working][workingIndex] = old
        guard let currentIndex = self[keyPath: operations.current].firstIndex(where: { $0.id == id }) else {
            pendingChanges[key] = operations.addition(old)
            trackChangeKey(key)
            return
        }
        let current = self[keyPath: operations.current][currentIndex]
        if old != current {
            pendingChanges[key] = operations.modification(current, old)
            trackChangeKey(key)
        } else {
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        }
    }

    private func applyAdditionUndo<Entity>(_ entity: Entity, using operations: SchemaEntityOperations<Entity>) {
        let removedIndex = self[keyPath: operations.working].firstIndex(where: { $0.id == entity.id })
        registerUndo(operations.addActionName) { target in
            target.applySchemaUndo(operations.deletionUndo(entity, removedIndex))
        }
        let key = operations.identifier(entity.id)
        if self[keyPath: operations.current].contains(where: { $0.id == entity.id }) {
            pendingChanges[key] = operations.deletion(entity)
            trackChangeKey(key)
        } else {
            self[keyPath: operations.working].removeAll { $0.id == entity.id }
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        }
    }

    private func applyDeletionUndo<Entity>(
        _ entity: Entity,
        at row: Int?,
        using operations: SchemaEntityOperations<Entity>
    ) {
        registerUndo(operations.deleteActionName) { target in
            target.applySchemaUndo(operations.additionUndo(entity))
        }
        let key = operations.identifier(entity.id)
        if self[keyPath: operations.current].contains(where: { $0.id == entity.id }) {
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        } else {
            if let row, row < self[keyPath: operations.working].count {
                self[keyPath: operations.working].insert(entity, at: row)
            } else {
                self[keyPath: operations.working].append(entity)
            }
            pendingChanges[key] = operations.addition(entity)
            trackChangeKey(key)
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
            return rowState(at: row, using: Self.columnOperations)
        case .indexes:
            return rowState(at: row, using: Self.indexOperations)
        case .foreignKeys:
            return rowState(at: row, using: Self.foreignKeyOperations)
        case .checkConstraints:
            return rowState(at: row, using: Self.checkConstraintOperations)
        case .ddl, .parts, .triggers:
            return (false, false)
        }
    }

    private func rowState<Entity>(
        at row: Int,
        using operations: SchemaEntityOperations<Entity>
    ) -> (isDeleted: Bool, isInserted: Bool) {
        guard row < self[keyPath: operations.working].count else { return (false, false) }
        let entity = self[keyPath: operations.working][row]
        let isDeleted = pendingChanges[operations.identifier(entity.id)]?.isDelete ?? false
        let isInserted = !self[keyPath: operations.current].contains { $0.id == entity.id }
        return (isDeleted, isInserted)
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
    case checkConstraintEdit(
        id: UUID, old: EditableCheckConstraintDefinition, new: EditableCheckConstraintDefinition
    )
    case checkConstraintAdd(constraint: EditableCheckConstraintDefinition)
    case checkConstraintDelete(constraint: EditableCheckConstraintDefinition, at: Int?)
    case primaryKeyChange(old: [String], new: [String])
}
