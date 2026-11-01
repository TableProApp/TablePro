//
//  SchemaEntityOperations.swift
//  TablePro
//

import Foundation

// One structure entity kind, for the staging sequence `StructureChangeManager` runs once for all four.
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
    // Whether the working copy needs a statement; a column's key flag is the table's key change, not the column's.
    var needsStatement: (_ loaded: Entity, _ working: Entity) -> Bool = { $0 != $1 }
}
