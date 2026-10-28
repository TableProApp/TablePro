//
//  StructureGridSupport.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// What the Structure and Create Table grids share: writing a cell into the working definitions, the
// row states the grid tints, and telling the model what changed.
@MainActor
enum StructureGridEdits {
    static let referencedTableField = 2

    @discardableResult
    static func apply(
        _ text: String,
        field: Int,
        sourceIndex: Int,
        tab: StructureTab,
        manager: StructureChangeManager,
        orderedFields: [StructureColumnField],
        connection: DatabaseConnection,
        characterSets: ColumnCharacterSetMenus.Context? = nil
    ) -> EditableForeignKeyDefinition? {
        switch tab {
        case .columns:
            guard manager.workingColumns.indices.contains(sourceIndex) else { return nil }
            var column = manager.workingColumns[sourceIndex]
            let value: String
            switch characterSetEntry(text, field: field, column: column, orderedFields: orderedFields, characterSets) {
            case .unchecked:
                value = text
            case .unchanged, .refused:
                return nil
            case .set(let characterSet, let collation):
                // The catalog's own spelling; the routing below pairs it with its default or owning set.
                value = (orderedFields[field] == .charset ? characterSet : collation) ?? ""
            }
            StructureEditingSupport.updateColumn(
                &column, at: field, with: value, orderedFields: orderedFields, catalog: characterSets?.loadedCatalog
            )
            manager.updateColumn(id: column.id, with: column)
        case .indexes:
            guard manager.workingIndexes.indices.contains(sourceIndex) else { return nil }
            var index = manager.workingIndexes[sourceIndex]
            StructureEditingSupport.updateIndex(
                &index,
                at: field,
                with: text,
                keys: StructureEditingSupport.indexKeyContext(for: manager, on: connection)
            )
            manager.updateIndex(id: index.id, with: index)
        case .foreignKeys:
            guard manager.workingForeignKeys.indices.contains(sourceIndex) else { return nil }
            var foreignKey = manager.workingForeignKeys[sourceIndex]
            StructureEditingSupport.updateForeignKey(&foreignKey, at: field, with: text)
            manager.updateForeignKey(id: foreignKey.id, with: foreignKey)
            return field == referencedTableField ? foreignKey : nil
        case .checkConstraints:
            guard manager.workingCheckConstraints.indices.contains(sourceIndex) else { return nil }
            var constraint = manager.workingCheckConstraints[sourceIndex]
            StructureEditingSupport.updateCheckConstraint(&constraint, at: field, with: text)
            manager.updateCheckConstraint(id: constraint.id, with: constraint)
        case .options, .ddl, .parts, .triggers:
            break
        }
        return nil
    }

    // A Charset or Collation name the catalog does not hold, or one typed while it cannot be checked.
    static func refuses(
        _ text: String,
        field: Int,
        sourceIndex: Int,
        tab: StructureTab,
        manager: StructureChangeManager,
        orderedFields: [StructureColumnField],
        characterSets: ColumnCharacterSetMenus.Context?
    ) -> Bool {
        guard tab == .columns, manager.workingColumns.indices.contains(sourceIndex) else { return false }
        let column = manager.workingColumns[sourceIndex]
        return characterSetEntry(text, field: field, column: column, orderedFields: orderedFields, characterSets) == .refused
    }

    private static func characterSetEntry(
        _ text: String,
        field: Int,
        column: EditableColumnDefinition,
        orderedFields: [StructureColumnField],
        _ characterSets: ColumnCharacterSetMenus.Context?
    ) -> ColumnCharacterSetMenus.Entry {
        guard let characterSets, orderedFields.indices.contains(field) else { return .unchecked }
        return ColumnCharacterSetMenus.entry(text, for: orderedFields[field], column: column, context: characterSets)
    }

    // One Cmd+Z brings the whole selection back: the manager registers an undo per row.
    static func delete(sourceIndices: [Int], tab: StructureTab, manager: StructureChangeManager) {
        manager.performAsOneUndoStep {
            for index in sourceIndices.sorted(by: >) {
                switch tab {
                case .columns:
                    guard manager.workingColumns.indices.contains(index) else { continue }
                    manager.deleteColumn(id: manager.workingColumns[index].id)
                case .indexes:
                    guard manager.workingIndexes.indices.contains(index) else { continue }
                    manager.deleteIndex(id: manager.workingIndexes[index].id)
                case .foreignKeys:
                    guard manager.workingForeignKeys.indices.contains(index) else { continue }
                    manager.deleteForeignKey(id: manager.workingForeignKeys[index].id)
                case .checkConstraints:
                    guard manager.workingCheckConstraints.indices.contains(index) else { continue }
                    manager.deleteCheckConstraint(id: manager.workingCheckConstraints[index].id)
                case .options, .ddl, .parts, .triggers:
                    break
                }
            }
        }
    }

    static func duplicate(sourceIndices: [Int], tab: StructureTab, manager: StructureChangeManager) {
        for index in sourceIndices.sorted() {
            switch tab {
            case .columns:
                guard manager.workingColumns.indices.contains(index) else { continue }
                manager.addColumn(manager.workingColumns[index].withNewIdentity())
            case .indexes:
                guard manager.workingIndexes.indices.contains(index) else { continue }
                var copy = manager.workingIndexes[index].withNewIdentity()
                copy.isPrimary = false
                manager.addIndex(copy)
            case .foreignKeys:
                guard manager.workingForeignKeys.indices.contains(index) else { continue }
                manager.addForeignKey(manager.workingForeignKeys[index].withNewIdentity())
            case .checkConstraints:
                guard manager.workingCheckConstraints.indices.contains(index) else { continue }
                manager.addCheckConstraint(manager.workingCheckConstraints[index].withNewIdentity())
            case .options, .ddl, .parts, .triggers:
                break
            }
        }
    }

    static func addRow(on tab: StructureTab, manager: StructureChangeManager) {
        switch tab {
        case .columns: manager.addNewColumn()
        case .indexes: manager.addNewIndex()
        case .foreignKeys: manager.addNewForeignKey()
        case .checkConstraints: manager.addNewCheckConstraint()
        case .options, .ddl, .parts, .triggers: break
        }
    }

    static func rowCount(on tab: StructureTab, manager: StructureChangeManager) -> Int {
        switch tab {
        case .columns: manager.workingColumns.count
        case .indexes: manager.workingIndexes.count
        case .foreignKeys: manager.workingForeignKeys.count
        case .checkConstraints: manager.workingCheckConstraints.count
        case .options, .ddl, .parts, .triggers: 0
        }
    }

    static func visualState(
        sourceIndex: Int,
        tab: StructureTab,
        manager: StructureChangeManager,
        orderedFields: [StructureColumnField],
        tintsModifiedFields: Bool
    ) -> RowVisualState {
        guard sourceIndex >= 0 else { return .empty }
        let (isDeleted, isInserted) = manager.deleteInsertState(for: sourceIndex, tab: tab)
        guard tintsModifiedFields, !isDeleted, !isInserted else {
            return RowVisualState(isDeleted: isDeleted, isInserted: isInserted, modifiedColumns: [])
        }
        return RowVisualState(
            isDeleted: false,
            isInserted: false,
            modifiedColumns: modifiedFields(sourceIndex: sourceIndex, tab: tab, manager: manager, orderedFields: orderedFields)
        )
    }

    private static func modifiedFields(
        sourceIndex: Int,
        tab: StructureTab,
        manager: StructureChangeManager,
        orderedFields: [StructureColumnField]
    ) -> Set<Int> {
        switch tab {
        case .columns:
            guard manager.workingColumns.indices.contains(sourceIndex) else { return [] }
            let working = manager.workingColumns[sourceIndex]
            guard let original = manager.currentColumns.first(where: { $0.id == working.id }) else { return [] }
            return StructureEditingSupport.columnModifiedIndices(old: original, new: working, orderedFields: orderedFields)
        case .indexes:
            guard manager.workingIndexes.indices.contains(sourceIndex) else { return [] }
            let working = manager.workingIndexes[sourceIndex]
            guard let original = manager.currentIndexes.first(where: { $0.id == working.id }) else { return [] }
            return StructureEditingSupport.indexModifiedIndices(old: original, new: working)
        case .foreignKeys:
            guard manager.workingForeignKeys.indices.contains(sourceIndex) else { return [] }
            let working = manager.workingForeignKeys[sourceIndex]
            guard let original = manager.currentForeignKeys.first(where: { $0.id == working.id }) else { return [] }
            return StructureEditingSupport.foreignKeyModifiedIndices(old: original, new: working)
        case .checkConstraints:
            guard manager.workingCheckConstraints.indices.contains(sourceIndex) else { return [] }
            let working = manager.workingCheckConstraints[sourceIndex]
            guard let original = manager.currentCheckConstraints.first(where: { $0.id == working.id }) else { return [] }
            return StructureEditingSupport.checkConstraintModifiedIndices(old: original, new: working)
        case .options, .ddl, .parts, .triggers:
            return []
        }
    }
}

// The schema manager has no row identities of its own; this answers the grid's row questions by the
// source-index RowIDs `StructureRowProvider` hands out.
@MainActor
final class StructureGridChangeState: ChangeManaging {
    let manager: StructureChangeManager
    var tab: StructureTab
    var rowCount: Int = 0

    init(manager: StructureChangeManager, tab: StructureTab = .columns) {
        self.manager = manager
        self.tab = tab
    }

    var hasChanges: Bool { manager.hasChanges }
    var reloadVersion: Int { manager.reloadVersion }
    var canRedo: Bool { manager.canRedo }
    var rowChanges: [RowChange] { [] }

    var insertedRowIDs: Set<RowID> {
        Set((0..<rowCount).filter { manager.deleteInsertState(for: $0, tab: tab).isInserted }
            .map(StructureRowProvider.rowID(forSourceIndex:)))
    }

    var deletedRowIDs: Set<RowID> {
        Set((0..<rowCount).filter { manager.deleteInsertState(for: $0, tab: tab).isDeleted }
            .map(StructureRowProvider.rowID(forSourceIndex:)))
    }

    func isRowDeleted(_ rowID: RowID) -> Bool {
        guard let index = StructureRowProvider.sourceIndex(of: rowID), index >= 0 else { return false }
        return manager.deleteInsertState(for: index, tab: tab).isDeleted
    }

    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?
    ) {}

    func undoRowDeletion(rowID: RowID) {
        guard let index = StructureRowProvider.sourceIndex(of: rowID) else { return }
        manager.undoDelete(for: tab, at: index)
    }
}

// The rows and row states one Structure or Create Table refresh produced.
struct StructureGridSnapshot {
    var rows = TableRows()
    var states: [RowVisualState] = []

    func state(for rowID: RowID) -> RowVisualState? {
        guard let index = rows.index(of: rowID), states.indices.contains(index) else { return nil }
        return states[index]
    }

    // Nil when the change needs a reload: other rows, other columns, or a row turning inserted or deleted.
    func changedCells(to next: StructureGridSnapshot) -> Set<CellPosition>? {
        guard rows.columns == next.rows.columns, rows.rows.count == next.rows.rows.count else { return nil }
        var changed: Set<CellPosition> = []
        for index in rows.rows.indices {
            let before = rows.rows[index]
            let after = next.rows.rows[index]
            guard before.id == after.id else { return nil }
            let oldState = states.indices.contains(index) ? states[index] : .empty
            let newState = next.states.indices.contains(index) ? next.states[index] : .empty
            guard oldState.isDeleted == newState.isDeleted, oldState.isInserted == newState.isInserted else { return nil }
            for column in 0..<max(before.values.count, after.values.count)
            where before[column] != after[column]
                || oldState.isModified(columnIndex: column) != newState.isModified(columnIndex: column) {
                changed.insert(CellPosition(row: index, column: column))
            }
        }
        return changed
    }
}

extension DataGridModel {
    // An owner that rebuilds whole rows reports them here; the model reloads only when it must.
    func applyHeldSnapshot(from previous: StructureGridSnapshot, to current: StructureGridSnapshot) {
        guard let cells = previous.changedCells(to: current) else {
            reloadHeldRows(columnsChanged: previous.rows.columns != current.rows.columns || columns.isEmpty)
            return
        }
        guard !cells.isEmpty else { return }
        apply(.cellsChanged(cells))
    }
}
