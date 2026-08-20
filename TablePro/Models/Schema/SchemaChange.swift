//
//  SchemaChange.swift
//  TablePro
//
//  Schema change operations for editable structure tab.
//  Represents ADD/MODIFY/DELETE operations on columns, indexes, and foreign keys.
//

import Foundation

/// Enum representing all possible schema change types
enum SchemaChange: Hashable, Equatable {
    case addColumn(EditableColumnDefinition)
    case modifyColumn(old: EditableColumnDefinition, new: EditableColumnDefinition)
    case deleteColumn(EditableColumnDefinition)

    case addIndex(EditableIndexDefinition)
    case modifyIndex(old: EditableIndexDefinition, new: EditableIndexDefinition)
    case deleteIndex(EditableIndexDefinition)

    case addForeignKey(EditableForeignKeyDefinition)
    case modifyForeignKey(old: EditableForeignKeyDefinition, new: EditableForeignKeyDefinition)
    case deleteForeignKey(EditableForeignKeyDefinition)

    case modifyPrimaryKey(old: [String], new: [String])

    /// Whether this change is a deletion
    var isDelete: Bool {
        switch self {
        case .deleteColumn, .deleteIndex, .deleteForeignKey:
            return true
        default:
            return false
        }
    }

    /// Whether this change is destructive (may cause data loss)
    var isDestructive: Bool {
        switch self {
        case .deleteColumn, .modifyColumn, .deleteIndex, .deleteForeignKey, .modifyPrimaryKey:
            return true
        default:
            return false
        }
    }

    /// Whether this change requires data migration
    var requiresDataMigration: Bool {
        switch self {
        case .modifyColumn(let old, let new):
            // Type changes or making nullable -> not nullable requires data check
            return old.dataType != new.dataType || (old.isNullable && !new.isNullable)
        case .deleteColumn, .modifyPrimaryKey:
            return true
        default:
            return false
        }
    }

    /// Human-readable description of the change
    var description: String {
        switch self {
        case .addColumn(let col):
            return "Add column '\(col.name)'"
        case .modifyColumn(let old, let new):
            return "Modify column '\(old.name)' to '\(new.name)'"
        case .deleteColumn(let col):
            return "Delete column '\(col.name)'"
        case .addIndex(let idx):
            return "Add index '\(idx.name)'"
        case .modifyIndex(let old, let new):
            return "Modify index '\(old.name)' to '\(new.name)'"
        case .deleteIndex(let idx):
            return "Delete index '\(idx.name)'"
        case .addForeignKey(let fk):
            return "Add foreign key '\(fk.name)'"
        case .modifyForeignKey(let old, let new):
            return "Modify foreign key '\(old.name)' to '\(new.name)'"
        case .deleteForeignKey(let fk):
            return "Delete foreign key '\(fk.name)'"
        case .modifyPrimaryKey(let old, let new):
            return "Change primary key from [\(old.joined(separator: ", "))] to [\(new.joined(separator: ", "))]"
        }
    }
}

/// Identifier for schema changes (used for tracking pending changes)
enum SchemaChangeIdentifier: Hashable {
    case column(UUID)
    case index(UUID)
    case foreignKey(UUID)
    case primaryKey
}
