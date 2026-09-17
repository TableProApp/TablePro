//
//  ReadIdentifiedDefinition.swift
//  TablePro
//
//  The `id` a structure definition carries names the read that produced it, not anything in the
//  database. Every catalog read mints fresh ones (`ColumnInfo.id = UUID()`), so two reads of a
//  table nobody touched are never equal while `id` takes part in the comparison.
//

import Foundation

internal protocol ReadIdentifiedDefinition {
    var id: UUID { get set }
}

internal extension ReadIdentifiedDefinition {
    /// The same definition under the one `id` every such copy shares. Assigning `id` rather than
    /// rebuilding the value is what keeps every other field, a field added later included, compared.
    func withoutIdentity() -> Self {
        var copy = self
        copy.id = unidentified
        return copy
    }
}

private let unidentified = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

extension EditableColumnDefinition: ReadIdentifiedDefinition {}
extension EditableIndexDefinition: ReadIdentifiedDefinition {}
extension EditableForeignKeyDefinition: ReadIdentifiedDefinition {}
extension EditableCheckConstraintDefinition: ReadIdentifiedDefinition {}

internal extension SchemaChange {
    func withoutIdentity() -> SchemaChange {
        switch self {
        case .addColumn(let column):
            return .addColumn(column.withoutIdentity())
        case .modifyColumn(let old, let new):
            return .modifyColumn(old: old.withoutIdentity(), new: new.withoutIdentity())
        case .deleteColumn(let column):
            return .deleteColumn(column.withoutIdentity())
        case .addIndex(let index):
            return .addIndex(index.withoutIdentity())
        case .modifyIndex(let old, let new):
            return .modifyIndex(old: old.withoutIdentity(), new: new.withoutIdentity())
        case .deleteIndex(let index):
            return .deleteIndex(index.withoutIdentity())
        case .addForeignKey(let foreignKey):
            return .addForeignKey(foreignKey.withoutIdentity())
        case .modifyForeignKey(let old, let new):
            return .modifyForeignKey(old: old.withoutIdentity(), new: new.withoutIdentity())
        case .deleteForeignKey(let foreignKey):
            return .deleteForeignKey(foreignKey.withoutIdentity())
        case .addCheckConstraint(let constraint):
            return .addCheckConstraint(constraint.withoutIdentity())
        case .modifyCheckConstraint(let old, let new):
            return .modifyCheckConstraint(old: old.withoutIdentity(), new: new.withoutIdentity())
        case .deleteCheckConstraint(let constraint):
            return .deleteCheckConstraint(constraint.withoutIdentity())
        case .modifyPrimaryKey:
            return self
        }
    }
}
