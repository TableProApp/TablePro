//
//  SchemaEntityOperations.swift
//  TablePro
//
//  Describes one structure-editor entity kind to the generic staging path.
//

import Foundation

/// What distinguishes one structure entity from another when it is staged.
///
/// Columns, indexes, foreign keys and check constraints are staged by an identical sequence:
/// register an undo, record a pending change under the entity's identifier, then write the
/// working array. Only the arrays, the enum cases and the undo action names differ, so those
/// are supplied here and the sequence itself lives once in `StructureChangeManager`.
struct SchemaEntityOperations<Entity: Identifiable & Equatable> where Entity.ID == UUID {
    let working: ReferenceWritableKeyPath<StructureChangeManager, [Entity]>
    let current: KeyPath<StructureChangeManager, [Entity]>
    let identifier: (UUID) -> SchemaChangeIdentifier
    let addition: (Entity) -> SchemaChange
    let modification: (Entity, Entity) -> SchemaChange
    let deletion: (Entity) -> SchemaChange
    let additionUndo: (Entity) -> SchemaUndoAction
    let editUndo: (UUID, Entity, Entity) -> SchemaUndoAction
    let deletionUndo: (Entity, Int?) -> SchemaUndoAction
    let addActionName: String
    let editActionName: String
    let deleteActionName: String
}
