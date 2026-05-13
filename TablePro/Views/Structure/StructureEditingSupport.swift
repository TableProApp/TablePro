//
//  StructureEditingSupport.swift
//  TablePro
//
//  Shared editing logic for updating structure entities by column index.
//  Used by both TableStructureView and CreateTableView to avoid
//  duplicated hardcoded index-to-field switch statements.
//

import Foundation
import TableProPluginKit

@MainActor
enum StructureEditingSupport {
    static func updateColumn(
        _ column: inout EditableColumnDefinition,
        at index: Int,
        with value: String,
        orderedFields: [StructureColumnField]
    ) {
        guard index >= 0, index < orderedFields.count else { return }
        switch orderedFields[index] {
        case .name: column.name = value
        case .type: column.dataType = value
        case .nullable: column.isNullable = value.uppercased() == "YES" || value == "1"
        case .defaultValue: column.defaultValue = value.isEmpty ? nil : value
        case .primaryKey: column.isPrimaryKey = value.uppercased() == "YES" || value == "1"
        case .autoIncrement: column.autoIncrement = value.uppercased() == "YES" || value == "1"
        case .comment: column.comment = value.isEmpty ? nil : value
        case .charset: column.charset = value.isEmpty ? nil : value
        case .collation: column.collation = value.isEmpty ? nil : value
        }
    }

    static func updateIndex(_ index: inout EditableIndexDefinition, at colIndex: Int, with value: String) {
        switch colIndex {
        case 0: index.name = value
        case 1:
            var prefixes: [String: Int] = [:]
            index.columns = value.split(separator: ",").map { part in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if let parenStart = trimmed.firstIndex(of: "("),
                   let parenEnd = trimmed.firstIndex(of: ")"),
                   let prefix = Int(trimmed[trimmed.index(after: parenStart)..<parenEnd]) {
                    let name = String(trimmed[..<parenStart])
                    prefixes[name] = prefix
                    return name
                }
                return trimmed
            }
            index.columnPrefixes = prefixes
        case 2:
            if let indexType = EditableIndexDefinition.IndexType(rawValue: value.uppercased()) {
                index.type = indexType
            }
        case 3: index.isUnique = value.uppercased() == "YES" || value == "1"
        case 4: index.whereClause = value.isEmpty ? nil : value
        default: break
        }
    }

    static func updateForeignKey(_ fk: inout EditableForeignKeyDefinition, at index: Int, with value: String) {
        switch index {
        case 0: fk.name = value
        case 1: fk.columns = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case 2: fk.referencedTable = value
        case 3: fk.referencedColumns = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case 4: fk.referencedSchema = value.isEmpty ? nil : value
        case 5:
            if let action = EditableForeignKeyDefinition.ReferentialAction(rawValue: value.uppercased()) {
                fk.onDelete = action
            }
        case 6:
            if let action = EditableForeignKeyDefinition.ReferentialAction(rawValue: value.uppercased()) {
                fk.onUpdate = action
            }
        default: break
        }
    }

    // MARK: - Field-Level Diff

    /// Per-cell modified-column tinting needs to know which display columns of
    /// a row actually changed. Each helper compares two entity values and
    /// returns the set of grid column indices whose value differs. Using these
    /// in `dataGridVisualState(forRow:)` lets the structure tab tint only the
    /// edited cells, mirroring the data tab's per-cell tinting instead of
    /// flagging the whole row when one field changed.

    static func columnModifiedIndices(
        old: EditableColumnDefinition,
        new: EditableColumnDefinition,
        orderedFields: [StructureColumnField]
    ) -> Set<Int> {
        var indices: Set<Int> = []
        for (index, field) in orderedFields.enumerated() where columnFieldDiffers(field, old: old, new: new) {
            indices.insert(index)
        }
        return indices
    }

    /// Grid columns: 0 Name, 1 Columns, 2 Type, 3 Unique, 4 Condition. Index 1
    /// covers `columns` and `columnPrefixes` together because prefixes render
    /// inline with the column list (`email(10)`). `isPrimary` and `comment` are
    /// intentionally excluded; neither has a grid column on the Indexes tab,
    /// so changes to them produce no tint. Matches the data-tab convention of
    /// only tinting fields the user can actually see.
    static func indexModifiedIndices(
        old: EditableIndexDefinition,
        new: EditableIndexDefinition
    ) -> Set<Int> {
        var indices: Set<Int> = []
        if old.name != new.name { indices.insert(0) }
        if old.columns != new.columns || old.columnPrefixes != new.columnPrefixes { indices.insert(1) }
        if old.type != new.type { indices.insert(2) }
        if old.isUnique != new.isUnique { indices.insert(3) }
        if old.whereClause != new.whereClause { indices.insert(4) }
        return indices
    }

    /// Grid columns: 0 Name, 1 Columns, 2 Ref Table, 3 Ref Columns, 4 Ref
    /// Schema, 5 On Delete, 6 On Update. Every field on
    /// `EditableForeignKeyDefinition` (except `id`) maps to a displayed column,
    /// so this diff is exhaustive. Adding a new field to the struct will need
    /// a new grid column AND a new comparison here.
    static func foreignKeyModifiedIndices(
        old: EditableForeignKeyDefinition,
        new: EditableForeignKeyDefinition
    ) -> Set<Int> {
        var indices: Set<Int> = []
        if old.name != new.name { indices.insert(0) }
        if old.columns != new.columns { indices.insert(1) }
        if old.referencedTable != new.referencedTable { indices.insert(2) }
        if old.referencedColumns != new.referencedColumns { indices.insert(3) }
        if old.referencedSchema != new.referencedSchema { indices.insert(4) }
        if old.onDelete != new.onDelete { indices.insert(5) }
        if old.onUpdate != new.onUpdate { indices.insert(6) }
        return indices
    }

    private static func columnFieldDiffers(
        _ field: StructureColumnField,
        old: EditableColumnDefinition,
        new: EditableColumnDefinition
    ) -> Bool {
        switch field {
        case .name: return old.name != new.name
        case .type: return old.dataType != new.dataType
        case .nullable: return old.isNullable != new.isNullable
        case .defaultValue: return old.defaultValue != new.defaultValue
        case .primaryKey: return old.isPrimaryKey != new.isPrimaryKey
        case .autoIncrement: return old.autoIncrement != new.autoIncrement
        case .comment: return old.comment != new.comment
        case .charset: return old.charset != new.charset
        case .collation: return old.collation != new.collation
        }
    }
}
