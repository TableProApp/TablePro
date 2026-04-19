//
//  StructureChangeManager.swift
//  TablePro
//
//  Manager for tracking structure/schema changes with O(1) lookups.
//  Mirrors DataChangeManager architecture for schema modifications.
//

import Foundation
import Observation

/// Manager for tracking and applying schema changes
@MainActor @Observable
final class StructureChangeManager {
    private(set) var pendingChanges: [SchemaChangeIdentifier: SchemaChange] = [:]
    @ObservationIgnored private var changeOrder: [SchemaChangeIdentifier] = []
    private(set) var validationErrors: [SchemaChangeIdentifier: String] = [:]
    var hasChanges: Bool { !pendingChanges.isEmpty }
    var reloadVersion: Int = 0

    // Track which rows changed since last reload for granular updates
    private(set) var changedRowIndices: Set<Int> = []

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
    var databaseType: DatabaseType = .mysql

    // MARK: - Undo/Redo Support

    private let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 100
        return manager
    }()
    private var visualStateCache: [VisualStateCacheKey: RowVisualState] = [:]

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    /// Consume and clear changed row indices (for granular table reloads)
    func consumeChangedRowIndices() -> Set<Int> {
        let indices = changedRowIndices
        changedRowIndices.removeAll()
        return indices
    }

    // MARK: - Load Schema

    func loadSchema(
        tableName: String,
        columns: [ColumnInfo],
        indexes: [IndexInfo],
        foreignKeys: [ForeignKeyInfo],
        primaryKey: [String],
        databaseType: DatabaseType
    ) {
        self.tableName = tableName
        self.databaseType = databaseType

        // Convert to definitions
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

        // Reset working state
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
        undoManager.registerUndo(withTarget: self) { target in
            target.applySchemaUndo(.columnAdd(column: placeholder))
        }
        undoManager.setActionName(String(localized: "Add Column"))
        validate()
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    func addNewIndex() {
        let placeholder = EditableIndexDefinition.placeholder()
        workingIndexes.append(placeholder)
        let key = SchemaChangeIdentifier.index(placeholder.id)
        pendingChanges[key] = .addIndex(placeholder)
        trackChangeKey(key)
        undoManager.registerUndo(withTarget: self) { target in
            target.applySchemaUndo(.indexAdd(index: placeholder))
        }
        undoManager.setActionName(String(localized: "Add Index"))
        validate()
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    func addNewForeignKey() {
        let placeholder = EditableForeignKeyDefinition.placeholder()
        workingForeignKeys.append(placeholder)
        let key = SchemaChangeIdentifier.foreignKey(placeholder.id)
        pendingChanges[key] = .addForeignKey(placeholder)
        trackChangeKey(key)
        undoManager.registerUndo(withTarget: self) { target in
            target.applySchemaUndo(.foreignKeyAdd(fk: placeholder))
        }
        undoManager.setActionName(String(localized: "Add Foreign Key"))
        validate()
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    // MARK: - Paste Operations (public methods for adding copied items)

    func addColumn(_ column: EditableColumnDefinition) {
        workingColumns.append(column)
        let key = SchemaChangeIdentifier.column(column.id)
        pendingChanges[key] = .addColumn(column)
        trackChangeKey(key)
        undoManager.registerUndo(withTarget: self) { target in
            target.applySchemaUndo(.columnAdd(column: column))
        }
        undoManager.setActionName(String(localized: "Add Column"))
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    func addIndex(_ index: EditableIndexDefinition) {
        workingIndexes.append(index)
        let key = SchemaChangeIdentifier.index(index.id)
        pendingChanges[key] = .addIndex(index)
        trackChangeKey(key)
        undoManager.registerUndo(withTarget: self) { target in
            target.applySchemaUndo(.indexAdd(index: index))
        }
        undoManager.setActionName(String(localized: "Add Index"))
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    func addForeignKey(_ foreignKey: EditableForeignKeyDefinition) {
        workingForeignKeys.append(foreignKey)
        let key = SchemaChangeIdentifier.foreignKey(foreignKey.id)
        pendingChanges[key] = .addForeignKey(foreignKey)
        trackChangeKey(key)
        undoManager.registerUndo(withTarget: self) { target in
            target.applySchemaUndo(.foreignKeyAdd(fk: foreignKey))
        }
        undoManager.setActionName(String(localized: "Add Foreign Key"))
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    // MARK: - Column Operations

    func updateColumn(id: UUID, with newColumn: EditableColumnDefinition) {
        // Capture old working state for undo BEFORE modifying
        if let workingIndex = workingColumns.firstIndex(where: { $0.id == id }) {
            let oldWorking = workingColumns[workingIndex]
            if oldWorking != newColumn {
                undoManager.registerUndo(withTarget: self) { target in
                    target.applySchemaUndo(.columnEdit(id: id, old: oldWorking, new: newColumn))
                }
                undoManager.setActionName(String(localized: "Edit Column"))
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
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    func deleteColumn(id: UUID) {
        let key = SchemaChangeIdentifier.column(id)
        if let column = currentColumns.first(where: { $0.id == id }) {
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.columnDelete(column: column, at: nil))
            }
            undoManager.setActionName(String(localized: "Delete Column"))
            pendingChanges[key] = .deleteColumn(column)
            trackChangeKey(key)
            if let rowIndex = workingColumns.firstIndex(where: { $0.id == id }) {
                changedRowIndices.insert(rowIndex)
            }
        } else {
            let rowIndex = workingColumns.firstIndex(where: { $0.id == id })
            if let column = workingColumns.first(where: { $0.id == id }) {
                undoManager.registerUndo(withTarget: self) { target in
                    target.applySchemaUndo(.columnDelete(column: column, at: rowIndex))
                }
                undoManager.setActionName(String(localized: "Delete Column"))
            }
            if let rowIndex {
                for i in rowIndex..<workingColumns.count {
                    changedRowIndices.insert(i)
                }
            }
            workingColumns.removeAll { $0.id == id }
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        }

        validate()
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    // MARK: - Index Operations

    func updateIndex(id: UUID, with newIndex: EditableIndexDefinition) {
        // Capture old working state for undo BEFORE modifying
        if let workingIdx = workingIndexes.firstIndex(where: { $0.id == id }) {
            let oldWorking = workingIndexes[workingIdx]
            if oldWorking != newIndex {
                undoManager.registerUndo(withTarget: self) { target in
                    target.applySchemaUndo(.indexEdit(id: id, old: oldWorking, new: newIndex))
                }
                undoManager.setActionName(String(localized: "Edit Index"))
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
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    func deleteIndex(id: UUID) {
        let key = SchemaChangeIdentifier.index(id)
        if let index = currentIndexes.first(where: { $0.id == id }) {
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.indexDelete(index: index, at: nil))
            }
            undoManager.setActionName(String(localized: "Delete Index"))
            pendingChanges[key] = .deleteIndex(index)
            trackChangeKey(key)
            if let rowIndex = workingIndexes.firstIndex(where: { $0.id == id }) {
                changedRowIndices.insert(rowIndex)
            }
        } else {
            let rowIndex = workingIndexes.firstIndex(where: { $0.id == id })
            if let index = workingIndexes.first(where: { $0.id == id }) {
                undoManager.registerUndo(withTarget: self) { target in
                    target.applySchemaUndo(.indexDelete(index: index, at: rowIndex))
                }
                undoManager.setActionName(String(localized: "Delete Index"))
            }
            if let rowIndex {
                for i in rowIndex..<workingIndexes.count {
                    changedRowIndices.insert(i)
                }
            }
            workingIndexes.removeAll { $0.id == id }
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        }

        validate()
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    // MARK: - Foreign Key Operations

    func updateForeignKey(id: UUID, with newFK: EditableForeignKeyDefinition) {
        // Capture old working state for undo BEFORE modifying
        if let workingIdx = workingForeignKeys.firstIndex(where: { $0.id == id }) {
            let oldWorking = workingForeignKeys[workingIdx]
            if oldWorking != newFK {
                undoManager.registerUndo(withTarget: self) { target in
                    target.applySchemaUndo(.foreignKeyEdit(id: id, old: oldWorking, new: newFK))
                }
                undoManager.setActionName(String(localized: "Edit Foreign Key"))
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
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    func deleteForeignKey(id: UUID) {
        let key = SchemaChangeIdentifier.foreignKey(id)
        if let fk = currentForeignKeys.first(where: { $0.id == id }) {
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.foreignKeyDelete(fk: fk, at: nil))
            }
            undoManager.setActionName(String(localized: "Delete Foreign Key"))
            pendingChanges[key] = .deleteForeignKey(fk)
            trackChangeKey(key)
            if let rowIndex = workingForeignKeys.firstIndex(where: { $0.id == id }) {
                changedRowIndices.insert(rowIndex)
            }
        } else {
            let rowIndex = workingForeignKeys.firstIndex(where: { $0.id == id })
            if let fk = workingForeignKeys.first(where: { $0.id == id }) {
                undoManager.registerUndo(withTarget: self) { target in
                    target.applySchemaUndo(.foreignKeyDelete(fk: fk, at: rowIndex))
                }
                undoManager.setActionName(String(localized: "Delete Foreign Key"))
            }
            if let rowIndex {
                for i in rowIndex..<workingForeignKeys.count {
                    changedRowIndices.insert(i)
                }
            }
            workingForeignKeys.removeAll { $0.id == id }
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        }

        validate()
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    // MARK: - Primary Key Operations

    func updatePrimaryKey(_ columns: [String]) {
        // Push undo action before modifying
        if columns != workingPrimaryKey {
            let oldPK = workingPrimaryKey
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.primaryKeyChange(old: oldPK, new: columns))
            }
            undoManager.setActionName(String(localized: "Change Primary Key"))
        }

        let key = SchemaChangeIdentifier.primaryKey
        if columns != currentPrimaryKey {
            pendingChanges[key] = .modifyPrimaryKey(old: currentPrimaryKey, new: columns)
            trackChangeKey(key)
        } else {
            pendingChanges.removeValue(forKey: key)
            untrackChangeKey(key)
        }

        workingPrimaryKey = columns
        validate()
    }

    // MARK: - Validation

    private func validate() {
        validationErrors.removeAll()

        // Validate all columns have name and dataType (no invalid placeholders)
        for column in workingColumns {
            if !column.isValid {
                validationErrors[.column(column.id)] = "Column must have a name and data type"
            }
        }

        // Validate column names are unique
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

        // Validate all indexes have required fields
        for index in workingIndexes {
            if !index.isValid {
                validationErrors[.index(index.id)] = "Index must have a name and at least one column"
            }
        }

        // Validate all foreign keys have required fields
        for fk in workingForeignKeys {
            if !fk.isValid {
                validationErrors[.foreignKey(fk.id)] = "Foreign key must have name, columns, and referenced table"
            }
        }

        // Validate index names are unique
        let indexNames = workingIndexes.filter { $0.isValid }.map { $0.name }
        let duplicateIndexes = Dictionary(grouping: indexNames, by: { $0 })
            .filter { $0.value.count > 1 }
            .map { $0.key }

        for duplicate in duplicateIndexes {
            for index in workingIndexes.filter({ $0.name == duplicate }) {
                validationErrors[.index(index.id)] = "Duplicate index name: \(duplicate)"
            }
        }

        // Validate index columns exist
        for index in workingIndexes.filter({ $0.isValid }) {
            for columnName in index.columns {
                if !columnNames.contains(columnName) {
                    validationErrors[.index(index.id)] = "Index references non-existent column: \(columnName)"
                }
            }
        }

        // Validate foreign key columns exist
        for fk in workingForeignKeys.filter({ $0.isValid }) {
            for columnName in fk.columns {
                if !columnNames.contains(columnName) {
                    validationErrors[.foreignKey(fk.id)] = "Foreign key references non-existent column: \(columnName)"
                }
            }
        }

        // Validate primary key columns exist
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
        changedRowIndices.removeAll()
        resetWorkingState()
        reloadVersion += 1
        rebuildVisualStateCache()
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
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.columnEdit(id: id, old: new, new: old))
            }
            undoManager.setActionName(String(localized: "Edit Column"))
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

        case .columnAdd(let column):
            let removedIndex = workingColumns.firstIndex(where: { $0.id == column.id })
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.columnDelete(column: column, at: removedIndex))
            }
            undoManager.setActionName(String(localized: "Add Column"))
            let addColKey = SchemaChangeIdentifier.column(column.id)
            if currentColumns.contains(where: { $0.id == column.id }) {
                pendingChanges[addColKey] = .deleteColumn(column)
                trackChangeKey(addColKey)
            } else {
                workingColumns.removeAll { $0.id == column.id }
                pendingChanges.removeValue(forKey: addColKey)
                untrackChangeKey(addColKey)
            }

        case .columnDelete(let column, let at):
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.columnAdd(column: column))
            }
            undoManager.setActionName(String(localized: "Delete Column"))
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

        case .indexEdit(let id, let old, let new):
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.indexEdit(id: id, old: new, new: old))
            }
            undoManager.setActionName(String(localized: "Edit Index"))
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

        case .indexAdd(let index):
            let removedIndex = workingIndexes.firstIndex(where: { $0.id == index.id })
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.indexDelete(index: index, at: removedIndex))
            }
            undoManager.setActionName(String(localized: "Add Index"))
            let idxAddKey = SchemaChangeIdentifier.index(index.id)
            if currentIndexes.contains(where: { $0.id == index.id }) {
                pendingChanges[idxAddKey] = .deleteIndex(index)
                trackChangeKey(idxAddKey)
            } else {
                workingIndexes.removeAll { $0.id == index.id }
                pendingChanges.removeValue(forKey: idxAddKey)
                untrackChangeKey(idxAddKey)
            }

        case .indexDelete(let index, let at):
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.indexAdd(index: index))
            }
            undoManager.setActionName(String(localized: "Delete Index"))
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

        case .foreignKeyEdit(let id, let old, let new):
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.foreignKeyEdit(id: id, old: new, new: old))
            }
            undoManager.setActionName(String(localized: "Edit Foreign Key"))
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

        case .foreignKeyAdd(let fk):
            let removedIndex = workingForeignKeys.firstIndex(where: { $0.id == fk.id })
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.foreignKeyDelete(fk: fk, at: removedIndex))
            }
            undoManager.setActionName(String(localized: "Add Foreign Key"))
            let fkAddKey = SchemaChangeIdentifier.foreignKey(fk.id)
            if currentForeignKeys.contains(where: { $0.id == fk.id }) {
                pendingChanges[fkAddKey] = .deleteForeignKey(fk)
                trackChangeKey(fkAddKey)
            } else {
                workingForeignKeys.removeAll { $0.id == fk.id }
                pendingChanges.removeValue(forKey: fkAddKey)
                untrackChangeKey(fkAddKey)
            }

        case .foreignKeyDelete(let fk, let at):
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.foreignKeyAdd(fk: fk))
            }
            undoManager.setActionName(String(localized: "Delete Foreign Key"))
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

        case .primaryKeyChange(let old, _):
            let current = workingPrimaryKey
            undoManager.registerUndo(withTarget: self) { target in
                target.applySchemaUndo(.primaryKeyChange(old: current, new: old))
            }
            undoManager.setActionName(String(localized: "Change Primary Key"))
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

        validate()
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    // MARK: - Visual State Management

    func getVisualState(for row: Int, tab: StructureTab) -> RowVisualState {
        let cacheKey = VisualStateCacheKey(tab: tab, row: row)
        if let cached = visualStateCache[cacheKey] {
            return cached
        }

        let state: RowVisualState

        switch tab {
        case .columns:
            guard row < workingColumns.count else { return .empty }
            let column = workingColumns[row]
            let change = pendingChanges[.column(column.id)]

            let isDeleted = change?.isDelete ?? false
            let isInserted = !currentColumns.contains(where: { $0.id == column.id })
            let isModified = change != nil && !isDeleted && !isInserted

            state = RowVisualState(
                isDeleted: isDeleted,
                isInserted: isInserted,
                modifiedColumns: isModified ? Set(0..<6) : []
            )

        case .indexes:
            guard row < workingIndexes.count else { return .empty }
            let index = workingIndexes[row]
            let change = pendingChanges[.index(index.id)]

            let isDeleted = change?.isDelete ?? false
            let isInserted = !currentIndexes.contains(where: { $0.id == index.id })
            let isModified = change != nil && !isDeleted && !isInserted

            state = RowVisualState(
                isDeleted: isDeleted,
                isInserted: isInserted,
                modifiedColumns: isModified ? Set(0..<5) : []
            )

        case .foreignKeys:
            guard row < workingForeignKeys.count else { return .empty }
            let fk = workingForeignKeys[row]
            let change = pendingChanges[.foreignKey(fk.id)]

            let isDeleted = change?.isDelete ?? false
            let isInserted = !currentForeignKeys.contains(where: { $0.id == fk.id })
            let isModified = change != nil && !isDeleted && !isInserted

            state = RowVisualState(
                isDeleted: isDeleted,
                isInserted: isInserted,
                modifiedColumns: isModified ? Set(0..<7) : []
            )

        case .ddl:
            state = .empty
        case .parts:
            state = .empty
        }

        visualStateCache[cacheKey] = state
        return state
    }

    func rebuildVisualStateCache() {
        visualStateCache.removeAll()
    }

    private struct VisualStateCacheKey: Hashable {
        let tab: StructureTab
        let row: Int
    }
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
