//
//  StructureChangeManager.swift
//  TablePro
//
//  Manager for tracking structure/schema changes with O(1) lookups.
//  Mirrors DataChangeManager architecture for schema modifications.
//

import Combine
import Foundation
import TableProPluginKit

/// Manager for tracking and applying schema changes
@MainActor
final class StructureChangeManager: ObservableObject, ChangeManaging {
    @Published private(set) var pendingChanges: [SchemaChangeIdentifier: SchemaChange] = [:]
    private var changeOrder: [SchemaChangeIdentifier] = []
    @Published private(set) var validationErrors: [SchemaChangeIdentifier: String] = [:]
    var hasChanges: Bool { !pendingChanges.isEmpty || holdsInvalidAutoIncrementEntry }
    @Published var reloadVersion: Int = 0

    // Current state (loaded from database)
    @Published private(set) var currentColumns: [EditableColumnDefinition] = []
    @Published private(set) var currentIndexes: [EditableIndexDefinition] = []
    @Published private(set) var currentForeignKeys: [EditableForeignKeyDefinition] = []
    @Published private(set) var currentCheckConstraints: [EditableCheckConstraintDefinition] = []
    @Published private(set) var currentPrimaryKey: [String] = []

    // Working state (includes uncommitted changes + placeholders)
    @Published var workingColumns: [EditableColumnDefinition] = []
    @Published var workingIndexes: [EditableIndexDefinition] = []
    @Published var workingForeignKeys: [EditableForeignKeyDefinition] = []
    @Published var workingCheckConstraints: [EditableCheckConstraintDefinition] = []
    // Derived from the columns after every change: the ones that stay and are marked Primary Key, the loaded members in
    // the loaded key's order, new ones after them in column order. A key nobody changed follows a rename by itself.
    @Published private(set) var workingPrimaryKey: [String] = []

    @Published var tableName: String?

    /// Indexes added as `CLUSTERED`, whose type `settleClusteredAdditions` keeps deciding until the
    /// user picks one for the row.
    private var indexesAddedClustered: Set<UUID> = []

    /// The edits a save in flight is writing, from the press until the save ends.
    ///
    /// While it is set nothing stages, undoes, discards or reloads. The save writes what it read at
    /// the press and clears it when it lands, so an edit accepted in between is missing from the
    /// script it runs and would then be cleared with the edits it did run. On MongoDB the time in
    /// between includes a read of every document the save changes, which can run for as long as
    /// the query timeout.
    @Published private(set) var heldSave: StructureSaveSnapshot?

    var isHeldForSave: Bool { heldSave != nil }

    @Published private(set) var tableComment = ObjectCommentDraft(original: nil)

    /// The comment text before the typing run still open, nil when none is. A run is one undo step,
    /// registered when it ends rather than per keystroke.
    private var tableCommentRunStart: String?

    var hasTableCommentRun: Bool { tableCommentRunStart != nil }

    private static var tableCommentActionName: String { String(localized: "Edit Comment") }

    @Published private(set) var tableOptions = TableOptionsDraft(original: nil)
    // Text in Next Auto Increment that is not a counter. It holds Save and counts as unsaved, so it is never dropped quietly.
    @Published private(set) var invalidAutoIncrementEntry: String?

    private static var tableOptionsActionName: String { String(localized: "Edit Table Options") }

    // MARK: - Undo/Redo Support

    /// Owned per manager so its actions cannot outlive the editor. Cmd+Z reaches it through
    /// `MainContentCommandActions.undoChange()`, not the window's undo manager.
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

    var canUndo: Bool { !isHeldForSave && (undoManager.canUndo || hasTableCommentRun || typingRun != nil) }
    var canRedo: Bool { !isHeldForSave && !hasTableCommentRun && typingRun == nil && undoManager.canRedo }

    var undoMenuItemTitle: String {
        if hasTableCommentRun { return undoManager.undoMenuTitle(forUndoActionName: Self.tableCommentActionName) }
        if let typingRun { return undoManager.undoMenuTitle(forUndoActionName: typingRun.actionName) }
        return undoManager.undoMenuItemTitle
    }

    // Typing in one field of one definition: every keystroke is staged, so Save, Refresh and the close prompt see it,
    // and the whole run undoes as one step. Anything else that registers an undo ends it first.
    private var typingRun: (key: String, actionName: String)?
    private var isStagingTyping = false

    func stageTyping(in key: String, actionName: String, _ body: () -> Void) {
        guard !isHeldForSave else { return }
        if typingRun?.key != key { endTypingRun() }
        if typingRun == nil {
            endTableCommentRun()
            undoManager.beginUndoGrouping()
            typingRun = (key, actionName)
        }
        isStagingTyping = true
        defer { isStagingTyping = false }
        body()
    }

    func endTypingRun() {
        guard typingRun != nil else { return }
        typingRun = nil
        undoManager.endUndoGrouping()
    }

    var redoMenuItemTitle: String { undoManager.redoMenuItemTitle }

    /// Mirrors `DataChangeManager.registerUndo`. The `groupingLevel` check is what lets
    /// `performAsOneUndoStep` nest: inside one, a group is already open and this adds to it rather
    /// than closing a group the batch still needs. An open comment run ends first, so an edit made
    /// after typing undoes before the typing does.
    private func registerUndo(_ actionName: String, _ handler: @escaping (StructureChangeManager) -> Void) {
        if !undoManager.isUndoing, !undoManager.isRedoing {
            endTableCommentRun()
            if !isStagingTyping { endTypingRun() }
        }
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
        guard !isHeldForSave else { return }
        endTableCommentRun()
        if !isStagingTyping { endTypingRun() }
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
        primaryKey: [String],
        tableComment: String? = nil,
        tableOptions: TableOptions? = nil,
        autoIncrementConfirmed: Bool = true
    ) {
        guard !isHeldForSave else { return }
        endTypingRun()
        self.tableName = tableName
        self.tableComment = ObjectCommentDraft(original: tableComment)
        tableCommentRunStart = nil
        self.tableOptions = TableOptionsDraft(original: tableOptions, isAutoIncrementConfirmed: autoIncrementConfirmed)
        invalidAutoIncrementEntry = nil

        self.currentColumns = columns.map { EditableColumnDefinition.from($0) }

        // Merge primary key info into columns (handles PostgreSQL where isPrimaryKey is always false)
        if !primaryKey.isEmpty {
            for i in currentColumns.indices {
                currentColumns[i].isPrimaryKey = primaryKey.contains(currentColumns[i].name)
            }
        }
        self.currentIndexes = indexes.map { EditableIndexDefinition.from($0) }
        self.currentForeignKeys = EditableForeignKeyDefinition.grouping(foreignKeys).sorted { $0.name < $1.name }
        self.currentCheckConstraints = checkConstraints.map { EditableCheckConstraintDefinition.from($0) }
        self.currentPrimaryKey = primaryKey
        keepIdentitiesAcrossReload()

        resetWorkingState()

        pendingChanges.removeAll()
        changeOrder.removeAll()
        validationErrors.removeAll()
        indexesAddedClustered.removeAll()
        undoManager.removeAllActions()

        // Increment reloadVersion to trigger DataGridView column width recalculation
        // This ensures columns auto-size based on actual cell content after initial load
        reloadVersion += 1
    }

    // Every fetch mints fresh ids; a definition that comes back under a name it had keeps its id, so the grid
    // selection and the inspector survive a refresh or a save.
    private func keepIdentitiesAcrossReload() {
        currentColumns = Self.keepingIDs(of: currentColumns, from: workingColumns, \.name, \.id)
        currentIndexes = Self.keepingIDs(of: currentIndexes, from: workingIndexes, \.name, \.id)
        currentForeignKeys = Self.keepingIDs(of: currentForeignKeys, from: workingForeignKeys, \.name, \.id)
        currentCheckConstraints = Self.keepingIDs(of: currentCheckConstraints, from: workingCheckConstraints, \.name, \.id)
    }

    private static func keepingIDs<Entity>(
        of loaded: [Entity],
        from earlier: [Entity],
        _ name: KeyPath<Entity, String>,
        _ id: WritableKeyPath<Entity, UUID>
    ) -> [Entity] {
        var ids: [String: UUID] = [:]
        for entity in earlier where !entity[keyPath: name].isEmpty && ids[entity[keyPath: name]] == nil {
            ids[entity[keyPath: name]] = entity[keyPath: id]
        }
        var used = Set<UUID>()
        return loaded.map { entity in
            guard let previous = ids[entity[keyPath: name]], used.insert(previous).inserted else { return entity }
            var kept = entity
            kept[keyPath: id] = previous
            return kept
        }
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
        stageAddition(EditableColumnDefinition.placeholder(), using: Self.columnOperations)
    }

    func addNewIndex() {
        stageAddition(EditableIndexDefinition.placeholder(), using: Self.indexOperations)
    }

    func addNewForeignKey() {
        stageAddition(EditableForeignKeyDefinition.placeholder(), using: Self.foreignKeyOperations)
    }

    func addNewCheckConstraint() {
        stageAddition(EditableCheckConstraintDefinition.placeholder(), using: Self.checkConstraintOperations)
    }

    // MARK: - Paste Operations (public methods for adding copied items)

    func addColumn(_ column: EditableColumnDefinition) {
        stageAddition(column, using: Self.columnOperations)
    }

    func addIndex(_ index: EditableIndexDefinition) {
        if index.type == .clustered {
            indexesAddedClustered.insert(index.id)
        }
        stageAddition(index, using: Self.indexOperations)
    }

    func addForeignKey(_ foreignKey: EditableForeignKeyDefinition) {
        stageAddition(foreignKey, using: Self.foreignKeyOperations)
    }

    func addCheckConstraint(_ constraint: EditableCheckConstraintDefinition) {
        stageAddition(constraint, using: Self.checkConstraintOperations)
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
        if workingIndexes.first(where: { $0.id == id })?.type != newIndex.type {
            indexesAddedClustered.remove(id)
        }
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
    ///
    /// Every addition revalidates, the pasted ones included. Save reads `canCommit`, which reads
    /// the errors this leaves behind, so a path that stages without validating puts a row into the
    /// save that nothing has checked.
    private func stageAddition<Entity>(
        _ entity: Entity,
        using operations: SchemaEntityOperations<Entity>
    ) {
        guard !isHeldForSave else { return }
        self[keyPath: operations.working].append(entity)
        let key = operations.identifier(entity.id)
        pendingChanges[key] = operations.addition(entity)
        trackChangeKey(key)
        registerUndo(operations.addActionName) { target in
            target.applySchemaUndo(operations.additionUndo(entity))
        }
        workingCopyDidChange()
    }

    private func stageEdit<Entity>(
        id: UUID,
        with newEntity: Entity,
        using operations: SchemaEntityOperations<Entity>
    ) {
        guard !isHeldForSave else { return }
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
            if operations.needsStatement(oldEntity, newEntity) {
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

        workingCopyDidChange()
    }

    private func stageDeletion<Entity>(id: UUID, using operations: SchemaEntityOperations<Entity>) {
        guard !isHeldForSave else { return }
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

        workingCopyDidChange()
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
        deleteActionName: String(localized: "Delete Column"),
        needsStatement: { loaded, working in
            var working = working
            working.isPrimaryKey = loaded.isPrimaryKey
            return loaded != working
        }
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

    // The row's own Undo Delete leaves the global stack alone, like the data tab's; an edit made before the
    // delete is staged again, since the working copy still shows it.
    func undoDelete(section: StructureSection, id: UUID) {
        guard !isHeldForSave else { return }
        switch section {
        case .columns: undoDeletion(id: id, using: Self.columnOperations)
        case .indexes: undoDeletion(id: id, using: Self.indexOperations)
        case .foreignKeys: undoDeletion(id: id, using: Self.foreignKeyOperations)
        case .checkConstraints: undoDeletion(id: id, using: Self.checkConstraintOperations)
        }
    }

    private func undoDeletion<Entity>(id: UUID, using operations: SchemaEntityOperations<Entity>) {
        let key = operations.identifier(id)
        guard pendingChanges[key]?.isDelete == true else { return }
        restageEdit(id: id, using: operations)
        workingCopyDidChange()
    }

    private func restageEdit<Entity>(id: UUID, using operations: SchemaEntityOperations<Entity>) {
        let key = operations.identifier(id)
        guard let loaded = self[keyPath: operations.current].first(where: { $0.id == id }),
              let working = self[keyPath: operations.working].first(where: { $0.id == id }),
              operations.needsStatement(loaded, working) else {
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
            return
        }
        pendingChanges[key] = operations.modification(loaded, working)
        trackChangeKey(key)
    }

    // MARK: - Validation

    /// Runs after every change to the working copy, undo and redo included: first what the change
    /// decides for rows it did not touch, then validation.
    private func workingCopyDidChange() {
        settleClusteredAdditions()
        restagePrimaryKey()
        validate()
    }

    /// A SQL Server table keeps its rows in the order of one clustered index, and its primary key is
    /// that index unless it says otherwise. An index added as `CLUSTERED`, which is what Duplicate
    /// and a paste stage for a copy of that index, takes the place only when no other index the
    /// table keeps after the save holds it, and is written `NONCLUSTERED` beside one that does, the
    /// type the server reports for every other index. Two `CLUSTERED` indexes are refused with
    /// "Cannot create more than one clustered index on table".
    ///
    /// Decided again after every change, because the place frees when its holder is deleted, and
    /// Duplicate, edit the copy, then delete the original is how an index is replaced. Decided once,
    /// the copy stayed `NONCLUSTERED` and the save left the table with no clustered index. A row
    /// whose type was changed to anything else is the user's own choice and is left alone.
    private func settleClusteredAdditions() {
        var placeIsTaken = workingIndexes.contains { index in
            !hasTypeSettledByTheEditor(index) && !isPendingDeletion(.index(index.id)) && index.type.ordersTableRows
        }
        for position in workingIndexes.indices where hasTypeSettledByTheEditor(workingIndexes[position]) {
            var index = workingIndexes[position]
            index.type = placeIsTaken ? .nonclustered : .clustered
            placeIsTaken = true
            guard index != workingIndexes[position] else { continue }
            workingIndexes[position] = index
            pendingChanges[.index(index.id)] = .addIndex(index)
        }
    }

    private func hasTypeSettledByTheEditor(_ index: EditableIndexDefinition) -> Bool {
        indexesAddedClustered.contains(index.id) && (index.type == .clustered || index.type == .nonclustered)
    }

    private func validate() {
        validationErrors.removeAll()

        let keptColumns = columnsAfterSave
        validateColumns(keptColumns)
        let columnNames = keptColumns.map(\.name)

        for index in workingIndexes where isStaged(.index(index.id)) && !index.isValid {
            validationErrors[.index(index.id)] = String(localized: "Index must have a name and at least one column")
        }

        for fk in workingForeignKeys where isStaged(.foreignKey(fk.id)) && !fk.isValid {
            validationErrors[.foreignKey(fk.id)] = String(
                localized: "Foreign key must have at least one column, a referenced table, and a referenced column"
            )
        }

        flagDuplicateNames(using: Self.indexOperations, name: \.name, isNamed: \.isValid, comparedAs: { $0 }) {
            String(format: String(localized: "Duplicate index name: %@"), $0)
        }

        /// Only a row this save actually edits is checked against the columns.
        ///
        /// An untouched index or foreign key names whatever it named when the table was read, and
        /// a rename in the same save leaves that name stale in the working copy without the user
        /// having done anything wrong: every engine's `RENAME COLUMN` carries the dependency over
        /// itself. Checking those rows would refuse a rename that works today. What this catches is
        /// a row the user is *editing* into a state the database will reject. An expression key names
        /// no column of its own, so an index is checked by its column names alone.
        for index in workingIndexes where isStaged(.index(index.id)) && index.isValid {
            for columnName in index.referencedColumnNames where !namesAColumn(columnName, in: columnNames) {
                validationErrors[.index(index.id)] = String(
                    format: String(localized: "Index references a column that does not exist: %@"), columnName
                )
            }
        }

        for fk in workingForeignKeys where isStaged(.foreignKey(fk.id)) && fk.isValid {
            for columnName in fk.columns where !namesAColumn(columnName, in: columnNames) {
                validationErrors[.foreignKey(fk.id)] = String(
                    format: String(localized: "Foreign key references a column that does not exist: %@"), columnName
                )
            }
            /// Only checkable when the key points back at the table being edited. For any other
            /// table the referenced columns are not in this editor, and the database is asked
            /// instead, when the change runs.
            guard let tableName,
                  fk.referencedTable.compare(tableName, options: .caseInsensitive) == .orderedSame else { continue }
            for columnName in fk.referencedColumns where !namesAColumn(columnName, in: columnNames) {
                validationErrors[.foreignKey(fk.id)] = String(
                    format: String(localized: "Foreign key points at a column that does not exist: %@"), columnName
                )
            }
        }

        for constraint in workingCheckConstraints where isStaged(.checkConstraint(constraint.id)) && !constraint.isValid {
            validationErrors[.checkConstraint(constraint.id)] = String(
                localized: "Check constraint must have a name and an expression"
            )
        }

        flagDuplicateNames(
            using: Self.checkConstraintOperations, name: \.name, isNamed: \.isValid, comparedAs: Self.constraintNameKey
        ) {
            String(format: String(localized: "Duplicate constraint name: %@"), $0)
        }
        flagChangesToASharedConstraintName()

        /// Checked only when this save changes the key, as the index and foreign key rows are. A
        /// rename leaves the loaded key naming the old spelling, and every engine's `RENAME COLUMN`
        /// carries the key over itself; dropping a key column is the database's to allow or refuse.
        for columnName in workingPrimaryKey where isStaged(.primaryKey) && !namesAColumn(columnName, in: columnNames) {
            validationErrors[.primaryKey] = String(
                format: String(localized: "Primary key references a column that does not exist: %@"), columnName
            )
        }

        validateAutoIncrement()
        validateConvert()
    }

    /// A MODIFY restates the loaded type, narrowing a TEXT the convert widened, and a replaced key is converted before it drops.
    private func validateConvert() {
        guard case .modifyTableCharacterSet(_, let new)? = pendingChanges[.tableCharacterSet], new.convertsColumns else {
            return
        }
        let restatesColumns = pendingChanges.values.contains { change in
            switch change {
            case .modifyColumn, .modifyPrimaryKey: true
            default: false
            }
        }
        guard restatesColumns else { return }
        validationErrors[.tableCharacterSet] = String(
            localized: "Save column and primary key changes before converting existing columns."
        )
    }

    /// Against the column as the save leaves it: a widening in the same save keeps a larger counter (MySQL 8.4, MariaDB 11.4).
    private func validateAutoIncrement() {
        if holdsInvalidAutoIncrementEntry, let invalidAutoIncrementEntry {
            validationErrors[.autoIncrement] = invalidAutoIncrementEntry
            return
        }
        guard case .modifyAutoIncrement(_, let value)? = pendingChanges[.autoIncrement] else { return }
        guard let range = autoIncrementRange else {
            validationErrors[.autoIncrement] = String(
                localized: "Next Auto Increment needs a column with AUTO_INCREMENT"
            )
            return
        }
        guard !range.contains(value) else { return }
        validationErrors[.autoIncrement] = String(
            format: String(localized: "Next Auto Increment must be between 1 and %@"), String(range.upperBound)
        )
    }

    /// Every column the table keeps after this save, whatever state its name and type are in.
    private var columnsAfterSave: [EditableColumnDefinition] {
        workingColumns.filter { !isPendingDeletion(.column($0.id)) }
    }

    var autoIncrementColumn: EditableColumnDefinition? {
        columnsAfterSave.first { $0.autoIncrement }
    }

    /// Nil without an AUTO_INCREMENT column; a type the range does not know is held to the counter's width.
    var autoIncrementRange: ClosedRange<UInt64>? {
        guard let column = autoIncrementColumn else { return nil }
        let maximum = AutoIncrementRange.maximum(forColumnType: column.dataType, unsigned: column.unsigned)
        return 1...(maximum ?? UInt64.max)
    }

    /// Only a column this save adds or changes is held to being complete.
    ///
    /// An untouched column is the database's own, and a typeless SQLite column or an empty MongoDB
    /// field name is no reason to refuse an edit made somewhere else. A duplicate name blocks only
    /// when the save put one of its columns there; an untouched pair stays the database's to judge.
    /// Every name the table will hold is compared, a blank one it was read with included, while a
    /// blank row still to be named is incomplete rather than a duplicate.
    private func validateColumns(_ keptColumns: [EditableColumnDefinition]) {
        let loadedColumns = Dictionary(currentColumns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for column in keptColumns where isStaged(.column(column.id)) {
            if column.isIncomplete(over: loadedColumns[column.id]) {
                validationErrors[.column(column.id)] = String(localized: "Column must have a name and a data type")
            } else if introducesNullDefaultOnNotNull(column) {
                validationErrors[.column(column.id)] = String(
                    format: String(localized: "%@ does not allow NULL, so its default cannot be NULL"), column.name
                )
            }
        }

        let savablyNamed = keptColumns.filter { $0.hasSavableName(over: loadedColumns[$0.id]) }
        let sameNamed = Dictionary(grouping: savablyNamed, by: \.name)
        for (name, columns) in sameNamed where columns.count > 1 {
            guard columns.contains(where: { isStaged(.column($0.id)) }) else { continue }
            for column in columns {
                validationErrors[.column(column.id)] = String(
                    format: String(localized: "Duplicate column name: %@"), name
                )
            }
        }
    }

    /// A name counts once for each row the table keeps, and blocks the save only when the save put
    /// one of those rows there, the rule columns follow.
    ///
    /// A row being deleted keeps nothing: the save drops every index and check constraint before it
    /// adds or renames one, so its name is free again by then. Deleting an index and adding one
    /// under its name used to be refused as a duplicate of the very row being dropped.
    ///
    /// `comparedAs` gives the key two names must share to be one name to the database.
    private func flagDuplicateNames<Entity>(
        using operations: SchemaEntityOperations<Entity>,
        name: KeyPath<Entity, String>,
        isNamed: KeyPath<Entity, Bool>,
        comparedAs key: (String) -> String,
        message: (String) -> String
    ) {
        let kept = self[keyPath: operations.working].filter {
            $0[keyPath: isNamed] && !isPendingDeletion(operations.identifier($0.id))
        }
        for rows in Dictionary(grouping: kept, by: { key($0[keyPath: name]) }).values where rows.count > 1 {
            guard rows.contains(where: { isStaged(operations.identifier($0.id)) }) else { continue }
            for row in rows {
                validationErrors[operations.identifier(row.id)] = message(row[keyPath: name])
            }
        }
    }

    /// SQLite and MariaDB treat `c` and `C` as one check constraint name: measured on SQLite 3.54,
    /// `ADD CONSTRAINT "C"` beside `c` fails with "constraint C already exists", and MariaDB 13.0.2
    /// refuses it with ERROR 1826. PostgreSQL keeps the two apart, and refusing such a pair there
    /// runs nothing.
    private static func constraintNameKey(_ name: String) -> String {
        name.lowercased()
    }

    /// SQLite accepts two table-level check constraints under one name, compares constraint names
    /// without regard to case, and drops the first one it finds by that name. So a change to one
    /// while another keeps the name can land on the other one. Changing every one of them is safe,
    /// because each is dropped by name and added back from its own new definition. PostgreSQL keeps
    /// `c` and `C` apart, and refusing a change to one of those runs nothing.
    private func flagChangesToASharedConstraintName() {
        let loaded = currentCheckConstraints.filter(\.isValid)
        for rows in Dictionary(grouping: loaded, by: { Self.constraintNameKey($0.name) }).values where rows.count > 1 {
            let changed = rows.filter { pendingChanges[.checkConstraint($0.id)] != nil }
            guard !changed.isEmpty, changed.count < rows.count else { continue }
            for row in changed {
                validationErrors[.checkConstraint(row.id)] = String(
                    format: String(localized: "More than one check constraint is named %@. Change or delete all of them in the same save."),
                    row.name
                )
            }
        }
    }

    /// Whether this save changes the row, and is not simply removing it.
    ///
    /// A row on its way out is not held to being complete: the user struck through a foreign key
    /// whose column is going with it, and demanding that it name a column that no longer exists
    /// would refuse the very edit they made.
    private func isStaged(_ key: SchemaChangeIdentifier) -> Bool {
        guard let change = pendingChanges[key] else { return false }
        return !change.isDelete
    }

    private func isPendingDeletion(_ key: SchemaChangeIdentifier) -> Bool {
        pendingChanges[key]?.isDelete == true
    }

    /// Identifiers compare case insensitively, the way every engine TablePro edits resolves them.
    /// SQLite accepts a column declared `ID` and referenced as `id`, and its pragmas report each
    /// spelling as written.
    private func namesAColumn(_ name: String, in columnNames: [String]) -> Bool {
        columnNames.contains { $0.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// MySQL and MariaDB refuse `NOT NULL DEFAULT NULL` with ERROR 1067. SQLite and DuckDB accept it,
    /// so a loaded column can already hold the pair, and an edit that leaves it as it was is not the
    /// user's to fix before the save.
    private func introducesNullDefaultOnNotNull(_ column: EditableColumnDefinition) -> Bool {
        guard !column.isNullable, column.hasNullDefault else { return false }
        guard let loaded = currentColumns.first(where: { $0.id == column.id }) else { return true }
        return loaded.isNullable || !loaded.hasNullDefault
    }

    // MARK: - State Management

    var canCommit: Bool {
        hasChanges && validationErrors.isEmpty
    }

    /// Every validation message, in one block, for the sheet that refuses the save.
    ///
    /// Sorted so the same set of problems reads the same way twice; the dictionary these come from
    /// is keyed by identifier and has no order of its own.
    var validationSummary: String {
        validationErrors.values.sorted().joined(separator: "\n")
    }

    func discardChanges() {
        guard !isHeldForSave else { return }
        endTypingRun()
        tableComment = ObjectCommentDraft(original: tableComment.original)
        tableCommentRunStart = nil
        tableOptions = TableOptionsDraft(
            original: tableOptions.original, isAutoIncrementConfirmed: tableOptions.isAutoIncrementConfirmed
        )
        invalidAutoIncrementEntry = nil
        pendingChanges.removeAll()
        changeOrder.removeAll()
        validationErrors.removeAll()
        indexesAddedClustered.removeAll()
        resetWorkingState()
        reloadVersion += 1
        undoManager.removeAllActions()
    }

    func getChangesArray() -> [SchemaChange] {
        changeOrder.compactMap { pendingChanges[$0] }
    }

    // MARK: - Save Hold

    /// Takes the staged edits for a save, or nil when there are none or a save already holds them.
    /// Taken before the save's first suspension, which is what refuses a second press.
    func holdForSave() -> StructureSaveSnapshot? {
        endTableCommentRun()
        endTypingRun()
        guard heldSave == nil, hasChanges else { return nil }
        let snapshot = StructureSaveSnapshot(changes: getChangesArray())
        heldSave = snapshot
        return snapshot
    }

    /// Ends the hold a save took. A save that wrote clears the staged edits only while they are
    /// still exactly the ones it read, so nothing it did not write is cleared, and a hold that has
    /// already ended cannot clear what was staged after it. Returns whether the edits were cleared.
    @discardableResult
    func releaseHold(_ snapshot: StructureSaveSnapshot, written: Bool) -> Bool {
        guard heldSave?.id == snapshot.id else { return false }
        heldSave = nil
        guard written, getChangesArray() == snapshot.changes else { return false }
        // The written comment is the new baseline now, or the field shows the old one until the refetch lands.
        for case .modifyTableComment(_, let savedComment) in snapshot.changes {
            tableComment = ObjectCommentDraft(original: savedComment)
        }
        var writtenOptions = tableOptions.original
        var isAutoIncrementConfirmed = tableOptions.isAutoIncrementConfirmed
        for change in snapshot.changes {
            switch change {
            case .modifyTableCharacterSet(_, let saved):
                writtenOptions = writtenOptions?.adoptingCharacterSet(of: saved)
            case .modifyAutoIncrement:
                // Left to the re-read: the server silently raises a value below the next free one.
                isAutoIncrementConfirmed = false
            default:
                continue
            }
        }
        tableOptions = TableOptionsDraft(original: writtenOptions, isAutoIncrementConfirmed: isAutoIncrementConfirmed)
        adoptWrittenDefinitions()
        discardChanges()
        return true
    }

    // The written definitions stand in until the re-read lands, so a renamed or new definition keeps its id, its
    // selection and the name the re-read is matched by.
    private func adoptWrittenDefinitions() {
        currentColumns = workingColumns.filter { !isPendingDeletion(.column($0.id)) }
        currentIndexes = workingIndexes.filter { !isPendingDeletion(.index($0.id)) }
        currentForeignKeys = workingForeignKeys.filter { !isPendingDeletion(.foreignKey($0.id)) }
        currentCheckConstraints = workingCheckConstraints.filter { !isPendingDeletion(.checkConstraint($0.id)) }
        currentPrimaryKey = workingPrimaryKey
    }

    // MARK: - Undo/Redo Operations

    func undo() {
        guard !isHeldForSave else { return }
        endTableCommentRun()
        endTypingRun()
        guard undoManager.canUndo else { return }
        undoManager.undo()
    }

    func redo() {
        guard !isHeldForSave else { return }
        endTableCommentRun()
        endTypingRun()
        guard undoManager.canRedo else { return }
        undoManager.redo()
    }

    // MARK: - Table Comment

    func stageTableComment(_ text: String) {
        guard !isHeldForSave, text != tableComment.text else { return }
        if tableCommentRunStart == nil {
            tableCommentRunStart = tableComment.text
        }
        tableComment.text = text
        restageTableComment()
    }

    func endTableCommentRun() {
        guard let start = tableCommentRunStart else { return }
        tableCommentRunStart = nil
        let end = tableComment.text
        guard start != end else { return }
        registerUndo(Self.tableCommentActionName) { target in
            target.applySchemaUndo(.tableCommentEdit(old: start, new: end))
        }
    }

    private func restageTableComment() {
        let key = SchemaChangeIdentifier.tableComment
        if tableComment.hasChanges {
            pendingChanges[key] = .modifyTableComment(old: tableComment.original, new: tableComment.commentToSave)
            trackChangeKey(key)
        } else {
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        }
    }

    private func applyTableCommentUndo(old: String, new: String) {
        registerUndo(Self.tableCommentActionName) { target in
            target.applySchemaUndo(.tableCommentEdit(old: new, new: old))
        }
        tableComment.text = old
        restageTableComment()
    }

    // MARK: - Table Options

    /// One whole-value write, so a collation never resolves against a stale character set.
    func stageTableOptions(_ options: TableOptions) {
        guard !isHeldForSave, let previous = tableOptions.current, options != previous else { return }
        // An unconfirmed baseline may be a counter the server already moved past.
        guard tableOptions.isAutoIncrementConfirmed || options.autoIncrement == previous.autoIncrement else { return }
        registerUndo(Self.tableOptionsActionName) { target in
            target.applySchemaUndo(.tableOptionsEdit(old: previous, new: options))
        }
        tableOptions.current = options
        restageTableOptions()
        workingCopyDidChange()
    }

    // The field goes with the last AUTO_INCREMENT column, and so does what was typed in it.
    private var holdsInvalidAutoIncrementEntry: Bool {
        invalidAutoIncrementEntry != nil && autoIncrementRange != nil
    }

    func noteAutoIncrementEntry(invalid message: String?) {
        guard !isHeldForSave, invalidAutoIncrementEntry != message else { return }
        invalidAutoIncrementEntry = message
        workingCopyDidChange()
    }

    private func restageTableOptions() {
        restage(.tableCharacterSet, as: tableOptions.characterSetChange)
        restage(.autoIncrement, as: tableOptions.autoIncrementChange)
    }

    private func restage(_ key: SchemaChangeIdentifier, as change: SchemaChange?) {
        if let change {
            pendingChanges[key] = change
            trackChangeKey(key)
        } else {
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        }
    }

    private func applyTableOptionsUndo(old: TableOptions, new: TableOptions) {
        registerUndo(Self.tableOptionsActionName) { target in
            target.applySchemaUndo(.tableOptionsEdit(old: new, new: old))
        }
        tableOptions.current = old
        restageTableOptions()
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
        case .primaryKeyChange:
            restagePrimaryKey()
        case .tableCommentEdit(let old, let new):
            applyTableCommentUndo(old: old, new: new)
        case .tableOptionsEdit(let old, let new):
            applyTableOptionsUndo(old: old, new: new)
        }

        workingCopyDidChange()
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
        if operations.needsStatement(current, old) {
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
            restageEdit(id: entity.id, using: operations)
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

    // MARK: - Primary key

    private func restagePrimaryKey() {
        let loadedIDs = currentPrimaryKey.compactMap { name in currentColumns.first { $0.name == name }?.id }
        let key = SchemaChangeIdentifier.primaryKey
        // A key naming a column that was not read (a failed read, an expression key) is left as it was loaded.
        guard loadedIDs.count == currentPrimaryKey.count else {
            workingPrimaryKey = currentPrimaryKey
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
            return
        }
        let members = workingColumns.filter { $0.isPrimaryKey && !isPendingDeletion(.column($0.id)) }
        let ordered = loadedIDs.compactMap { id in members.first { $0.id == id } }
            + members.filter { !loadedIDs.contains($0.id) }
        workingPrimaryKey = ordered.map(\.name)
        // A key that only loses columns being dropped needs no statement: the database takes them out with the column,
        // and on MySQL an AUTO_INCREMENT key cannot be dropped before its column.
        let survivingLoadedIDs = loadedIDs.filter { !isPendingDeletion(.column($0)) }
        if ordered.map(\.id) == loadedIDs || ordered.map(\.id) == survivingLoadedIDs {
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        } else {
            pendingChanges[key] = .modifyPrimaryKey(old: currentPrimaryKey, new: workingPrimaryKey)
            trackChangeKey(key)
        }
    }

    // MARK: - Visual State Management

    /// Per-row delete/insert flags. Modified-column tinting is computed by the
    /// `StructureGridDelegate` because it requires the tab's `orderedFields`
    /// (which depends on the database type and is a UI concern). The delegate
    /// merges the result of this method with `modifiedColumns` from
    /// `StructureEditingSupport` field-diff helpers to build the final
    /// `RowVisualState`.
    func deleteInsertState(for row: Int, tab: StructureSection) -> (isDeleted: Bool, isInserted: Bool) {
        switch tab {
        case .columns:
            return rowState(at: row, using: Self.columnOperations)
        case .indexes:
            return rowState(at: row, using: Self.indexOperations)
        case .foreignKeys:
            return rowState(at: row, using: Self.foreignKeyOperations)
        case .checkConstraints:
            return rowState(at: row, using: Self.checkConstraintOperations)
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

    var insertedRowIDs: Set<RowID> { [] }

    func isRowDeleted(_ rowID: RowID) -> Bool { false }

    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?
    ) {}

    func undoRowDeletion(rowID: RowID) {}
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
    /// The field's raw text, so undo restores exactly what was typed.
    case tableCommentEdit(old: String, new: String)
    case tableOptionsEdit(old: TableOptions, new: TableOptions)
}

/// The staged edits a save read when it was pressed, and so the only edits it may clear.
struct StructureSaveSnapshot: Equatable {
    let id = UUID()
    let changes: [SchemaChange]
}
