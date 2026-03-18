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
    private(set) var validationErrors: [SchemaChangeIdentifier: String] = [:]
    var hasChanges: Bool = false
    var reloadVersion: Int = 0  // Incremented to trigger table reload

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

    private let undoManager = StructureUndoManager()
    private var visualStateCache: [Int: RowVisualState] = [:]

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
                onDelete: EditableForeignKeyDefinition.ReferentialAction(rawValue: first.onDelete.uppercased()) ?? .noAction,
                onUpdate: EditableForeignKeyDefinition.ReferentialAction(rawValue: first.onUpdate.uppercased()) ?? .noAction
            )
        }
        self.currentPrimaryKey = primaryKey

        // Reset working state
        resetWorkingState()

        // Clear changes
        pendingChanges.removeAll()
        validationErrors.removeAll()
        hasChanges = false

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

    // MARK: - Add New Rows

    func addNewColumn() {
        let placeholder = EditableColumnDefinition.placeholder()
        workingColumns.append(placeholder)
        // Mark as pending change so hasChanges = true (even though placeholder is invalid)
        // This allows Cmd+R to show warning and Cmd+S to trigger validation
        pendingChanges[.column(placeholder.id)] = .addColumn(placeholder)
        undoManager.push(.columnAdd(column: placeholder))
        validate()
        hasChanges = true
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    func addNewIndex() {
        let placeholder = EditableIndexDefinition.placeholder()
        workingIndexes.append(placeholder)
        pendingChanges[.index(placeholder.id)] = .addIndex(placeholder)
        undoManager.push(.indexAdd(index: placeholder))
        validate()
        hasChanges = true
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    func addNewForeignKey() {
        let placeholder = EditableForeignKeyDefinition.placeholder()
        workingForeignKeys.append(placeholder)
        pendingChanges[.foreignKey(placeholder.id)] = .addForeignKey(placeholder)
        undoManager.push(.foreignKeyAdd(fk: placeholder))
        validate()
        hasChanges = true
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    // MARK: - Paste Operations (public methods for adding copied items)

    func addColumn(_ column: EditableColumnDefinition) {
        workingColumns.append(column)
        pendingChanges[.column(column.id)] = .addColumn(column)
        undoManager.push(.columnAdd(column: column))
        hasChanges = true
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    func addIndex(_ index: EditableIndexDefinition) {
        workingIndexes.append(index)
        pendingChanges[.index(index.id)] = .addIndex(index)
        undoManager.push(.indexAdd(index: index))
        hasChanges = true
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    func addForeignKey(_ foreignKey: EditableForeignKeyDefinition) {
        workingForeignKeys.append(foreignKey)
        pendingChanges[.foreignKey(foreignKey.id)] = .addForeignKey(foreignKey)
        undoManager.push(.foreignKeyAdd(fk: foreignKey))
        hasChanges = true
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    // MARK: - Column Operations

    func updateColumn(id: UUID, with newColumn: EditableColumnDefinition) {
        // Capture old working state for undo BEFORE modifying
        if let workingIndex = workingColumns.firstIndex(where: { $0.id == id }) {
            let oldWorking = workingColumns[workingIndex]
            if oldWorking != newColumn {
                undoManager.push(.columnEdit(id: id, old: oldWorking, new: newColumn))
            }
        }

        // Find if it's existing or new
        if let index = currentColumns.firstIndex(where: { $0.id == id }) {
            let oldColumn = currentColumns[index]
            if oldColumn != newColumn {
                pendingChanges[.column(id)] = .modifyColumn(old: oldColumn, new: newColumn)
            } else {
                pendingChanges.removeValue(forKey: .column(id))
            }
        } else {
            // New column - allow saving even if invalid - let database validate
            pendingChanges[.column(id)] = .addColumn(newColumn)
        }

        // Update working state
        if let index = workingColumns.firstIndex(where: { $0.id == id }) {
            workingColumns[index] = newColumn
        }

        validate()
        hasChanges = !pendingChanges.isEmpty
        reloadVersion += 1  // Trigger table reload to show visual changes
        rebuildVisualStateCache()  // Rebuild cache to reflect updated state
    }

    func deleteColumn(id: UUID) {
        // Check if it's an existing column (from database) or a new column (not yet saved)
        if let column = currentColumns.first(where: { $0.id == id }) {
            // Existing column - mark as deleted (keep in workingColumns for visual feedback)
            undoManager.push(.columnDelete(column: column))
            pendingChanges[.column(id)] = .deleteColumn(column)
            // Track changed row for reload
            if let rowIndex = workingColumns.firstIndex(where: { $0.id == id }) {
                changedRowIndices.insert(rowIndex)
            }
        } else {
            // New column that hasn't been saved yet - remove from list
            if let column = workingColumns.first(where: { $0.id == id }) {
                undoManager.push(.columnDelete(column: column))
            }
            if let rowIndex = workingColumns.firstIndex(where: { $0.id == id }) {
                // Track ALL rows from this index onwards for reload (indices shift down)
                for i in rowIndex..<workingColumns.count {
                    changedRowIndices.insert(i)
                }
            }
            workingColumns.removeAll { $0.id == id }
            pendingChanges.removeValue(forKey: .column(id))
        }

        validate()
        hasChanges = !pendingChanges.isEmpty
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    // MARK: - Index Operations

    func updateIndex(id: UUID, with newIndex: EditableIndexDefinition) {
        // Capture old working state for undo BEFORE modifying
        if let workingIdx = workingIndexes.firstIndex(where: { $0.id == id }) {
            let oldWorking = workingIndexes[workingIdx]
            if oldWorking != newIndex {
                undoManager.push(.indexEdit(id: id, old: oldWorking, new: newIndex))
            }
        }

        if let index = currentIndexes.firstIndex(where: { $0.id == id }) {
            let oldIndex = currentIndexes[index]
            if oldIndex != newIndex {
                pendingChanges[.index(id)] = .modifyIndex(old: oldIndex, new: newIndex)
            } else {
                pendingChanges.removeValue(forKey: .index(id))
            }
        } else {
            // Allow saving even if invalid - let database validate
            pendingChanges[.index(id)] = .addIndex(newIndex)
        }

        if let index = workingIndexes.firstIndex(where: { $0.id == id }) {
            workingIndexes[index] = newIndex
        }

        validate()
        hasChanges = !pendingChanges.isEmpty
        reloadVersion += 1  // Trigger table reload to show visual changes
        rebuildVisualStateCache()  // Rebuild cache to reflect updated state
    }

    func deleteIndex(id: UUID) {
        // Check if it's an existing index or a new index
        if let index = currentIndexes.first(where: { $0.id == id }) {
            // Existing index - mark as deleted (keep in workingIndexes for visual feedback)
            undoManager.push(.indexDelete(index: index))
            pendingChanges[.index(id)] = .deleteIndex(index)
            // Track changed row for reload
            if let rowIndex = workingIndexes.firstIndex(where: { $0.id == id }) {
                changedRowIndices.insert(rowIndex)
            }
        } else {
            // New index that hasn't been saved yet - remove from list
            if let index = workingIndexes.first(where: { $0.id == id }) {
                undoManager.push(.indexDelete(index: index))
            }
            if let rowIndex = workingIndexes.firstIndex(where: { $0.id == id }) {
                // Track ALL rows from this index onwards for reload (indices shift down)
                for i in rowIndex..<workingIndexes.count {
                    changedRowIndices.insert(i)
                }
            }
            workingIndexes.removeAll { $0.id == id }
            pendingChanges.removeValue(forKey: .index(id))
        }

        validate()
        hasChanges = !pendingChanges.isEmpty
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    // MARK: - Foreign Key Operations

    func updateForeignKey(id: UUID, with newFK: EditableForeignKeyDefinition) {
        // Capture old working state for undo BEFORE modifying
        if let workingIdx = workingForeignKeys.firstIndex(where: { $0.id == id }) {
            let oldWorking = workingForeignKeys[workingIdx]
            if oldWorking != newFK {
                undoManager.push(.foreignKeyEdit(id: id, old: oldWorking, new: newFK))
            }
        }

        if let index = currentForeignKeys.firstIndex(where: { $0.id == id }) {
            let oldFK = currentForeignKeys[index]
            if oldFK != newFK {
                pendingChanges[.foreignKey(id)] = .modifyForeignKey(old: oldFK, new: newFK)
            } else {
                pendingChanges.removeValue(forKey: .foreignKey(id))
            }
        } else {
            // Allow saving even if invalid - let database validate
            pendingChanges[.foreignKey(id)] = .addForeignKey(newFK)
        }

        if let index = workingForeignKeys.firstIndex(where: { $0.id == id }) {
            workingForeignKeys[index] = newFK
        }

        validate()
        hasChanges = !pendingChanges.isEmpty
        reloadVersion += 1  // Trigger table reload to show visual changes
        rebuildVisualStateCache()  // Rebuild cache to reflect updated state
    }

    func deleteForeignKey(id: UUID) {
        // Check if it's an existing foreign key or a new foreign key
        if let fk = currentForeignKeys.first(where: { $0.id == id }) {
            // Existing FK - mark as deleted (keep in workingForeignKeys for visual feedback)
            undoManager.push(.foreignKeyDelete(fk: fk))
            pendingChanges[.foreignKey(id)] = .deleteForeignKey(fk)
            // Track changed row for reload
            if let rowIndex = workingForeignKeys.firstIndex(where: { $0.id == id }) {
                changedRowIndices.insert(rowIndex)
            }
        } else {
            // New FK that hasn't been saved yet - remove from list
            if let fk = workingForeignKeys.first(where: { $0.id == id }) {
                undoManager.push(.foreignKeyDelete(fk: fk))
            }
            if let rowIndex = workingForeignKeys.firstIndex(where: { $0.id == id }) {
                // Track ALL rows from this index onwards for reload (indices shift down)
                for i in rowIndex..<workingForeignKeys.count {
                    changedRowIndices.insert(i)
                }
            }
            workingForeignKeys.removeAll { $0.id == id }
            pendingChanges.removeValue(forKey: .foreignKey(id))
        }

        validate()
        hasChanges = !pendingChanges.isEmpty
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    // MARK: - Primary Key Operations

    func updatePrimaryKey(_ columns: [String]) {
        // Push undo action before modifying
        if columns != workingPrimaryKey {
            undoManager.push(.primaryKeyChange(old: workingPrimaryKey, new: columns))
        }

        if columns != currentPrimaryKey {
            pendingChanges[.primaryKey] = .modifyPrimaryKey(old: currentPrimaryKey, new: columns)
        } else {
            pendingChanges.removeValue(forKey: .primaryKey)
        }

        workingPrimaryKey = columns
        validate()
        hasChanges = !pendingChanges.isEmpty
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
            if let column = workingColumns.first(where: { $0.name == duplicate }) {
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
            if let index = workingIndexes.first(where: { $0.name == duplicate }) {
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
        validationErrors.removeAll()
        changedRowIndices.removeAll()  // Clear changed row tracking
        hasChanges = false
        resetWorkingState()
        reloadVersion += 1
        rebuildVisualStateCache()
        undoManager.clearAll()
    }

    func getChangesArray() -> [SchemaChange] {
        Array(pendingChanges.values)
    }

    // MARK: - Undo/Redo Operations

    func undo() {
        guard let action = undoManager.undo() else { return }
        applyUndoAction(action, isRedo: false)
    }

    func redo() {
        guard let action = undoManager.redo() else { return }
        applyUndoAction(action, isRedo: true)
    }

    private func applyUndoAction(_ action: SchemaUndoAction, isRedo: Bool) {
        switch action {
        case .columnEdit(let id, let old, let new):
            let column = isRedo ? new : old
            if let index = workingColumns.firstIndex(where: { $0.id == id }) {
                workingColumns[index] = column
                if let currentIndex = currentColumns.firstIndex(where: { $0.id == id }) {
                    let current = currentColumns[currentIndex]
                    if column != current {
                        pendingChanges[.column(id)] = .modifyColumn(old: current, new: column)
                    } else {
                        pendingChanges.removeValue(forKey: .column(id))
                    }
                }
            }

        case .columnAdd(let column):
            if isRedo {
                workingColumns.append(column)
                pendingChanges[.column(column.id)] = .addColumn(column)
            } else {
                workingColumns.removeAll { $0.id == column.id }
                pendingChanges.removeValue(forKey: .column(column.id))
            }

        case .columnDelete(let column):
            if isRedo {
                // For existing columns, keep in workingColumns for strikethrough; for new columns, remove
                if currentColumns.contains(where: { $0.id == column.id }) {
                    pendingChanges[.column(column.id)] = .deleteColumn(column)
                } else {
                    workingColumns.removeAll { $0.id == column.id }
                    pendingChanges.removeValue(forKey: .column(column.id))
                }
            } else {
                // Undo delete: if column is still in workingColumns (existing, kept for strikethrough),
                // just clear pending change. If physically removed (new column), re-add it.
                if workingColumns.contains(where: { $0.id == column.id }) {
                    pendingChanges.removeValue(forKey: .column(column.id))
                } else {
                    workingColumns.append(column)
                    pendingChanges[.column(column.id)] = .addColumn(column)
                }
            }

        case .indexEdit(let id, let old, let new):
            let index = isRedo ? new : old
            if let idx = workingIndexes.firstIndex(where: { $0.id == id }) {
                workingIndexes[idx] = index
                if let currentIdx = currentIndexes.firstIndex(where: { $0.id == id }) {
                    let current = currentIndexes[currentIdx]
                    if index != current {
                        pendingChanges[.index(id)] = .modifyIndex(old: current, new: index)
                    } else {
                        pendingChanges.removeValue(forKey: .index(id))
                    }
                }
            }

        case .indexAdd(let index):
            if isRedo {
                workingIndexes.append(index)
                pendingChanges[.index(index.id)] = .addIndex(index)
            } else {
                workingIndexes.removeAll { $0.id == index.id }
                pendingChanges.removeValue(forKey: .index(index.id))
            }

        case .indexDelete(let index):
            if isRedo {
                // For existing indexes, keep in workingIndexes for strikethrough; for new indexes, remove
                if currentIndexes.contains(where: { $0.id == index.id }) {
                    pendingChanges[.index(index.id)] = .deleteIndex(index)
                } else {
                    workingIndexes.removeAll { $0.id == index.id }
                    pendingChanges.removeValue(forKey: .index(index.id))
                }
            } else {
                // Undo delete: if index is still in workingIndexes (existing, kept for strikethrough),
                // just clear pending change. If physically removed (new index), re-add it.
                if workingIndexes.contains(where: { $0.id == index.id }) {
                    pendingChanges.removeValue(forKey: .index(index.id))
                } else {
                    workingIndexes.append(index)
                    pendingChanges[.index(index.id)] = .addIndex(index)
                }
            }

        case .foreignKeyEdit(let id, let old, let new):
            let fk = isRedo ? new : old
            if let idx = workingForeignKeys.firstIndex(where: { $0.id == id }) {
                workingForeignKeys[idx] = fk
                if let currentIdx = currentForeignKeys.firstIndex(where: { $0.id == id }) {
                    let current = currentForeignKeys[currentIdx]
                    if fk != current {
                        pendingChanges[.foreignKey(id)] = .modifyForeignKey(old: current, new: fk)
                    } else {
                        pendingChanges.removeValue(forKey: .foreignKey(id))
                    }
                }
            }

        case .foreignKeyAdd(let fk):
            if isRedo {
                workingForeignKeys.append(fk)
                pendingChanges[.foreignKey(fk.id)] = .addForeignKey(fk)
            } else {
                workingForeignKeys.removeAll { $0.id == fk.id }
                pendingChanges.removeValue(forKey: .foreignKey(fk.id))
            }

        case .foreignKeyDelete(let fk):
            if isRedo {
                // For existing FKs, keep in workingForeignKeys for strikethrough; for new FKs, remove
                if currentForeignKeys.contains(where: { $0.id == fk.id }) {
                    pendingChanges[.foreignKey(fk.id)] = .deleteForeignKey(fk)
                } else {
                    workingForeignKeys.removeAll { $0.id == fk.id }
                    pendingChanges.removeValue(forKey: .foreignKey(fk.id))
                }
            } else {
                // Undo delete: if FK is still in workingForeignKeys (existing, kept for strikethrough),
                // just clear pending change. If physically removed (new FK), re-add it.
                if workingForeignKeys.contains(where: { $0.id == fk.id }) {
                    pendingChanges.removeValue(forKey: .foreignKey(fk.id))
                } else {
                    workingForeignKeys.append(fk)
                    pendingChanges[.foreignKey(fk.id)] = .addForeignKey(fk)
                }
            }

        case .primaryKeyChange(let old, let new):
            workingPrimaryKey = isRedo ? new : old
            if workingPrimaryKey != currentPrimaryKey {
                pendingChanges[.primaryKey] = .modifyPrimaryKey(old: currentPrimaryKey, new: workingPrimaryKey)
            } else {
                pendingChanges.removeValue(forKey: .primaryKey)
            }
        }

        hasChanges = !pendingChanges.isEmpty
        reloadVersion += 1
        rebuildVisualStateCache()
    }

    // MARK: - Visual State Management

    func getVisualState(for row: Int, tab: StructureTab) -> RowVisualState {
        // Check cache first
        let tabIndex: Int
        switch tab {
        case .columns: tabIndex = 0
        case .indexes: tabIndex = 1
        case .foreignKeys: tabIndex = 2
        case .ddl: tabIndex = 3
        case .parts: tabIndex = 4
        }
        let cacheKey = tabIndex * 10_000 + row
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
                modifiedColumns: isModified ? Set(0..<4) : []
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
                modifiedColumns: isModified ? Set(0..<6) : []
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
}
