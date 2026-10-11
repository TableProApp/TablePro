//
//  SchemaChange.swift
//  TablePro
//

import Foundation

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

    case addCheckConstraint(EditableCheckConstraintDefinition)
    case modifyCheckConstraint(old: EditableCheckConstraintDefinition, new: EditableCheckConstraintDefinition)
    case deleteCheckConstraint(EditableCheckConstraintDefinition)

    case modifyPrimaryKey(old: [String], new: [String])

    /// Nil on either side means no comment.
    case modifyTableComment(old: String?, new: String?)

    var isDelete: Bool {
        switch self {
        case .deleteColumn, .deleteIndex, .deleteForeignKey, .deleteCheckConstraint:
            return true
        default:
            return false
        }
    }

    var isDestructive: Bool {
        switch self {
        case .deleteColumn, .modifyColumn, .deleteIndex, .deleteForeignKey, .modifyPrimaryKey,
             .deleteCheckConstraint:
            return true
        case .modifyCheckConstraint(let old, let new):
            // Renaming is one statement that touches no rows. Only a changed expression drops and
            // re-adds the constraint, which re-checks the whole table.
            return old.expression != new.expression
        default:
            return false
        }
    }

    var requiresDataMigration: Bool {
        switch self {
        case .modifyColumn(let old, let new):
            return old.dataType != new.dataType || (old.isNullable && !new.isNullable)
        case .deleteColumn, .modifyPrimaryKey:
            return true
        case .addCheckConstraint:
            return true
        case .modifyCheckConstraint(let old, let new):
            return old.expression != new.expression
        default:
            return false
        }
    }

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
        case .addCheckConstraint(let constraint):
            return "Add check constraint '\(constraint.name)'"
        case .modifyCheckConstraint(let old, let new):
            return "Modify check constraint '\(old.name)' to '\(new.name)'"
        case .deleteCheckConstraint(let constraint):
            return "Delete check constraint '\(constraint.name)'"
        case .modifyPrimaryKey(let old, let new):
            return "Change primary key from [\(old.joined(separator: ", "))] to [\(new.joined(separator: ", "))]"
        case .modifyTableComment:
            return "Change comment on table"
        }
    }
}

enum SchemaChangeIdentifier: Hashable {
    case column(UUID)
    case index(UUID)
    case foreignKey(UUID)
    case checkConstraint(UUID)
    case primaryKey
    case tableComment
}
