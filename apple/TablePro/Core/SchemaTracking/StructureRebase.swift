//
//  StructureRebase.swift
//  TablePro
//

import Foundation

// Matches one kind of structure definition, as read after a save that stopped part way, to the staged edits.
@MainActor
enum StructureRebase {
    struct Entities<Entity> {
        let current: [Entity]
        let working: [Entity]
        let staleKeys: [SchemaChangeIdentifier]
        let changes: [(key: SchemaChangeIdentifier, change: SchemaChange)]
    }

    struct Baseline {
        let columns: [EditableColumnDefinition]
        let indexes: [EditableIndexDefinition]
        let foreignKeys: [EditableForeignKeyDefinition]
        let checkConstraints: [EditableCheckConstraintDefinition]
        let primaryKey: [String]
        let comment: ObjectCommentDraft
        let options: TableOptionsDraft

        init(
            columns: [ColumnInfo],
            indexes: [IndexInfo],
            foreignKeys: [ForeignKeyInfo],
            checkConstraints: [CheckConstraintInfo] = [],
            primaryKey: [String],
            tableComment: String? = nil,
            tableOptions: TableOptions? = nil,
            autoIncrementConfirmed: Bool = true
        ) {
            var loaded = columns.map { EditableColumnDefinition.from($0) }
            if !primaryKey.isEmpty {
                for index in loaded.indices {
                    loaded[index].isPrimaryKey = primaryKey.contains(loaded[index].name)
                }
            }
            self.columns = loaded
            self.indexes = indexes.map { EditableIndexDefinition.from($0) }
            self.foreignKeys = EditableForeignKeyDefinition.grouping(foreignKeys).sorted { $0.name < $1.name }
            self.checkConstraints = checkConstraints.map { EditableCheckConstraintDefinition.from($0) }
            self.primaryKey = primaryKey
            comment = ObjectCommentDraft(original: tableComment)
            options = TableOptionsDraft(original: tableOptions, isAutoIncrementConfirmed: autoIncrementConfirmed)
        }
    }

    // A column's key flag is the table's key change, so the one the user set outlives the adopted definition.
    static func keepingKeyFlags(
        of rebased: [EditableColumnDefinition],
        from working: [EditableColumnDefinition]
    ) -> [EditableColumnDefinition] {
        let flags = Dictionary(working.map { ($0.id, $0.isPrimaryKey) }, uniquingKeysWith: { first, _ in first })
        return rebased.map { column in
            guard let flag = flags[column.id] else { return column }
            var kept = column
            kept.isPrimaryKey = flag
            return kept
        }
    }

    static func entities<Entity>(
        onto loaded: [Entity],
        in manager: StructureChangeManager,
        using operations: SchemaEntityOperations<Entity>,
        _ name: KeyPath<Entity, String>,
        _ id: WritableKeyPath<Entity, UUID>
    ) -> Entities<Entity> {
        let working = manager[keyPath: operations.working]
        let deleted = working.map(\.id).filter { manager.pendingChanges[operations.identifier($0)]?.isDelete == true }
        return entities(
            loaded: loaded,
            earlier: manager[keyPath: operations.current],
            working: working,
            deleted: Set(deleted),
            using: operations,
            name,
            id
        )
    }

    static func entities<Entity>(
        loaded: [Entity],
        earlier: [Entity],
        working: [Entity],
        deleted: Set<UUID>,
        using operations: SchemaEntityOperations<Entity>,
        _ name: KeyPath<Entity, String>,
        _ id: WritableKeyPath<Entity, UUID>
    ) -> Entities<Entity> {
        // The name a definition has after the save, then the one it had before: a rename that ran is found under
        // the first, one that did not under the second.
        var idsAfterSave: [String: UUID] = [:]
        for entity in working where !deleted.contains(entity.id) {
            let entityName = entity[keyPath: name]
            if !entityName.isEmpty, idsAfterSave[entityName] == nil { idsAfterSave[entityName] = entity.id }
        }
        var idsBeforeSave: [String: UUID] = [:]
        for entity in earlier {
            let entityName = entity[keyPath: name]
            if !entityName.isEmpty, idsBeforeSave[entityName] == nil { idsBeforeSave[entityName] = entity.id }
        }
        let earlierByID = Dictionary(earlier.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let loadedNames = Set(loaded.map { $0[keyPath: name] })
        func reads(_ entity: Entity, as held: Entity?) -> Bool {
            guard let held else { return false }
            var probe = entity
            probe[keyPath: id] = held.id
            return probe == held
        }
        // A deleted definition and another one that takes its name: the drop runs first, so the table still holds the
        // deleted one while a rename into the name has not run, or while it reads as it did before the save. A rename
        // whose old name another definition takes leaves no such evidence, and the renamed one is matched as before.
        func stillHoldsDeleted(_ entity: Entity, deleted before: UUID, taker after: UUID) -> Bool {
            if let renamedFrom = earlierByID[after]?[keyPath: name], renamedFrom != entity[keyPath: name] {
                return idsAfterSave[renamedFrom] == nil && loadedNames.contains(renamedFrom)
            }
            return reads(entity, as: earlierByID[before])
        }
        var used = Set<UUID>()
        let current: [Entity] = loaded.map { entity in
            let entityName = entity[keyPath: name]
            var candidates = [idsAfterSave[entityName], idsBeforeSave[entityName]].compactMap { $0 }
            if let before = idsBeforeSave[entityName], deleted.contains(before),
               let after = idsAfterSave[entityName], after != before,
               stillHoldsDeleted(entity, deleted: before, taker: after) {
                candidates = [before, after]
            }
            if entityName.isEmpty {
                // A definition with no name is the one it was when nothing else about it changed.
                candidates = earlier.filter { reads(entity, as: $0) }.map(\.id)
            }
            guard let kept = candidates.first(where: { !used.contains($0) }) else { return entity }
            used.insert(kept)
            var matched = entity
            matched[keyPath: id] = kept
            return matched
        }

        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rebasedWorking: [Entity] = []
        var changes: [(key: SchemaChangeIdentifier, change: SchemaChange)] = []
        for entity in working {
            let key = operations.identifier(entity.id)
            guard let baseline = currentByID[entity.id] else {
                // A deletion that ran leaves nothing to show; anything else the table lacks is still to be added.
                guard !deleted.contains(entity.id) else { continue }
                rebasedWorking.append(entity)
                changes.append((key: key, change: operations.addition(entity)))
                continue
            }
            if deleted.contains(entity.id) {
                rebasedWorking.append(entity)
                changes.append((key: key, change: operations.deletion(baseline)))
                continue
            }
            // An addition the table now has ran. An edit is still owed only where the table differs from it.
            guard let before = earlierByID[entity.id],
                  operations.needsStatement(before, entity),
                  operations.needsStatement(baseline, entity)
            else {
                rebasedWorking.append(baseline)
                continue
            }
            rebasedWorking.append(entity)
            changes.append((key: key, change: operations.modification(baseline, entity)))
        }
        let shown = Set(rebasedWorking.map(\.id))
        rebasedWorking.append(contentsOf: current.filter { !shown.contains($0.id) })

        return Entities(
            current: current,
            working: rebasedWorking,
            staleKeys: (working + earlier).map { operations.identifier($0.id) },
            changes: changes
        )
    }
}
