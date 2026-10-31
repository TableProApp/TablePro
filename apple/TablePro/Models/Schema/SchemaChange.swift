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

    /// The default character set and collation, or with `convertsColumns` every text column too.
    case modifyTableCharacterSet(old: TableOptions, new: TableOptions)
    /// Old is nil when the table had no AUTO_INCREMENT column when it was read.
    case modifyAutoIncrement(old: UInt64?, new: UInt64)

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
        case .modifyTableCharacterSet(_, let new):
            // A convert rewrites every text column, can widen TEXT and loses what the new set cannot hold.
            return new.convertsColumns
        default:
            return false
        }
    }

    // A new character set converts the stored text, and what it cannot hold is lost. A table default is nil.
    private static func changesCharacterSet(from old: String?, to new: String?) -> Bool {
        switch (old, new) {
        case (nil, nil):
            return false
        case let (old?, new?):
            return old.caseInsensitiveCompare(new) != .orderedSame
        default:
            return true
        }
    }

    var requiresDataMigration: Bool {
        switch self {
        case .modifyColumn(let old, let new):
            return old.dataType != new.dataType || (old.isNullable && !new.isNullable)
                || Self.changesCharacterSet(from: old.charset, to: new.charset)
        case .deleteColumn, .modifyPrimaryKey:
            return true
        case .addCheckConstraint:
            return true
        case .modifyCheckConstraint(let old, let new):
            return old.expression != new.expression
        case .modifyTableCharacterSet(_, let new):
            return new.convertsColumns
        default:
            return false
        }
    }

    // What an error or a review shows a person; `description` stays English for logs.
    var localizedDescription: String {
        switch self {
        case .addColumn(let col):
            return String(format: String(localized: "Add column “%@”"), col.name)
        case .modifyColumn(let old, let new):
            return old.name == new.name
                ? String(format: String(localized: "Change column “%@”"), new.name)
                : String(format: String(localized: "Change column “%@” to “%@”"), old.name, new.name)
        case .deleteColumn(let col):
            return String(format: String(localized: "Delete column “%@”"), col.name)
        case .addIndex(let idx):
            return String(format: String(localized: "Add index “%@”"), idx.name)
        case .modifyIndex(let old, let new):
            return old.name == new.name
                ? String(format: String(localized: "Change index “%@”"), new.name)
                : String(format: String(localized: "Change index “%@” to “%@”"), old.name, new.name)
        case .deleteIndex(let idx):
            return String(format: String(localized: "Delete index “%@”"), idx.name)
        case .addForeignKey(let fk):
            return String(format: String(localized: "Add foreign key “%@”"), fk.name)
        case .modifyForeignKey(let old, let new):
            return old.name == new.name
                ? String(format: String(localized: "Change foreign key “%@”"), new.name)
                : String(format: String(localized: "Change foreign key “%@” to “%@”"), old.name, new.name)
        case .deleteForeignKey(let fk):
            return String(format: String(localized: "Delete foreign key “%@”"), fk.name)
        case .addCheckConstraint(let constraint):
            return String(format: String(localized: "Add check constraint “%@”"), constraint.name)
        case .modifyCheckConstraint(let old, let new):
            return old.name == new.name
                ? String(format: String(localized: "Change check constraint “%@”"), new.name)
                : String(format: String(localized: "Change check constraint “%@” to “%@”"), old.name, new.name)
        case .deleteCheckConstraint(let constraint):
            return String(format: String(localized: "Delete check constraint “%@”"), constraint.name)
        case .modifyPrimaryKey(_, let new):
            return new.isEmpty
                ? String(localized: "Remove the primary key")
                : String(format: String(localized: "Set the primary key to %@"), new.joined(separator: ", "))
        case .modifyTableComment:
            return String(localized: "Change the table comment")
        case .modifyTableCharacterSet(_, let new):
            let target = [new.characterSet, new.collation].compactMap { $0 }.joined(separator: " ")
            return new.convertsColumns
                ? String(format: String(localized: "Convert the table to %@"), target)
                : String(format: String(localized: "Set the table's default character set to %@"), target)
        case .modifyAutoIncrement(_, let new):
            return String(format: String(localized: "Set the next AUTO_INCREMENT value to %@"), String(new))
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
        case .modifyTableCharacterSet(_, let new):
            let target = [new.characterSet, new.collation].compactMap { $0 }.joined(separator: " ")
            return new.convertsColumns
                ? "Convert table to \(target)"
                : "Change default character set of table to \(target)"
        case .modifyAutoIncrement(_, let new):
            return "Set AUTO_INCREMENT of table to \(new)"
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
    case tableCharacterSet
    case autoIncrement
}
