import Foundation
import TableProConnectionLibrary
import TableProModels

nonisolated struct ConnectionLibraryChange: Equatable, Sendable {
    let connections: [DatabaseConnection]
    let changedConnectionIds: [UUID]
}

nonisolated struct GroupLibraryChange: Equatable, Sendable {
    let groups: [ConnectionGroup]
    let connections: [DatabaseConnection]
    let changedGroupIds: [UUID]
    let removedGroupIds: [UUID]
    let changedConnectionIds: [UUID]
}

nonisolated struct TagLibraryChange: Equatable, Sendable {
    let tags: [ConnectionTag]
    let connections: [DatabaseConnection]
    let removedTagId: UUID
    let changedConnectionIds: [UUID]
}

nonisolated enum ConnectionLibraryEditing {
    static func effectiveGroupId(of connection: DatabaseConnection, validGroupIds: Set<UUID>) -> UUID? {
        connection.groupId.flatMap { validGroupIds.contains($0) ? $0 : nil }
    }

    static func nextSortOrder(
        in connections: [DatabaseConnection],
        groupId: UUID?,
        validGroupIds: Set<UUID>
    ) -> Int {
        LibraryOrdering.nextSortOrder(
            after: connections
                .filter { effectiveGroupId(of: $0, validGroupIds: validGroupIds) == groupId }
                .map(\.sortOrder)
        )
    }

    static func adding(
        _ connection: DatabaseConnection,
        to connections: [DatabaseConnection],
        validGroupIds: Set<UUID>
    ) -> ConnectionLibraryChange {
        var placed = connection
        placed.sortOrder = nextSortOrder(
            in: connections,
            groupId: effectiveGroupId(of: connection, validGroupIds: validGroupIds),
            validGroupIds: validGroupIds
        )
        return ConnectionLibraryChange(connections: connections + [placed], changedConnectionIds: [placed.id])
    }

    static func mutatingConnection(
        _ id: UUID,
        in connections: [DatabaseConnection],
        validGroupIds: Set<UUID>,
        _ mutate: (inout DatabaseConnection) -> Void
    ) -> ConnectionLibraryChange? {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return nil }
        let stored = connections[index]
        var updated = stored
        mutate(&updated)
        updated.id = id
        let targetGroup = effectiveGroupId(of: updated, validGroupIds: validGroupIds)
        if effectiveGroupId(of: stored, validGroupIds: validGroupIds) != targetGroup {
            updated.sortOrder = nextSortOrder(
                in: connections.filter { $0.id != id },
                groupId: targetGroup,
                validGroupIds: validGroupIds
            )
        }
        guard updated != stored else {
            return ConnectionLibraryChange(connections: connections, changedConnectionIds: [])
        }
        var result = connections
        result[index] = updated
        return ConnectionLibraryChange(connections: result, changedConnectionIds: [id])
    }

    static func moving(
        _ ids: [UUID],
        toGroup groupId: UUID?,
        before: UUID? = nil,
        in connections: [DatabaseConnection],
        validGroupIds: Set<UUID>
    ) -> ConnectionLibraryChange {
        let existing = Set(connections.map(\.id))
        var seen: Set<UUID> = []
        let moving = ids.filter { existing.contains($0) && seen.insert($0).inserted }
        let movingSet = Set(moving)
        let siblings = LibrarySorting.sorted(
            connections.filter { connection in
                !movingSet.contains(connection.id)
                    && effectiveGroupId(of: connection, validGroupIds: validGroupIds) == groupId
            },
            mode: .manual
        )

        let ranks: [UUID: Int]
        if let before, siblings.contains(where: { $0.id == before }) {
            ranks = LibraryOrdering.ranks(
                for: LibraryOrdering.reordered(siblings.map(\.id), moving: moving, before: before)
            )
        } else {
            let start = LibraryOrdering.nextSortOrder(after: siblings.map(\.sortOrder))
            ranks = Dictionary(uniqueKeysWithValues: moving.enumerated().map { ($0.element, start + $0.offset) })
        }

        return applying(to: connections) { connection in
            if movingSet.contains(connection.id) {
                connection.groupId = groupId
            }
            if let rank = ranks[connection.id] {
                connection.sortOrder = rank
            }
        }
    }

    static func reordering(_ orderedIds: [UUID], in connections: [DatabaseConnection]) -> ConnectionLibraryChange {
        let ranks = LibraryOrdering.ranks(for: orderedIds)
        return applying(to: connections) { connection in
            if let rank = ranks[connection.id] {
                connection.sortOrder = rank
            }
        }
    }

    static func settingFavorite(
        _ ids: Set<UUID>,
        to isFavorite: Bool,
        in connections: [DatabaseConnection]
    ) -> ConnectionLibraryChange {
        applying(to: connections) { connection in
            if ids.contains(connection.id) {
                connection.isFavorite = isFavorite
            }
        }
    }

    static func renaming(_ id: UUID, to name: String, in connections: [DatabaseConnection]) -> ConnectionLibraryChange {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ConnectionLibraryChange(connections: connections, changedConnectionIds: [])
        }
        return applying(to: connections) { connection in
            if connection.id == id {
                connection.name = trimmed
            }
        }
    }

    static func duplicating(
        _ source: DatabaseConnection,
        named name: String,
        newId: UUID = UUID(),
        in connections: [DatabaseConnection],
        validGroupIds: Set<UUID>
    ) -> (change: ConnectionLibraryChange, copy: DatabaseConnection) {
        var copy = source
        copy.id = newId
        copy.name = name
        copy.isFavorite = false

        let groupId = effectiveGroupId(of: source, validGroupIds: validGroupIds)
        let siblings = LibrarySorting.sorted(
            connections.filter { effectiveGroupId(of: $0, validGroupIds: validGroupIds) == groupId },
            mode: .manual
        )
        let following = siblings.firstIndex { $0.id == source.id }.flatMap { index in
            siblings.indices.contains(index + 1) ? siblings[index + 1].id : nil
        }
        let ranks = LibraryOrdering.ranks(
            for: LibraryOrdering.reordered(siblings.map(\.id), moving: [newId], before: following)
        )
        copy.sortOrder = ranks[newId] ?? LibraryOrdering.nextSortOrder(after: siblings.map(\.sortOrder))

        let renumbered = applying(to: connections) { connection in
            if let rank = ranks[connection.id] {
                connection.sortOrder = rank
            }
        }
        let change = ConnectionLibraryChange(
            connections: renumbered.connections + [copy],
            changedConnectionIds: renumbered.changedConnectionIds + [newId]
        )
        return (change, copy)
    }

    static func addingGroup(_ group: ConnectionGroup, to groups: [ConnectionGroup]) -> [ConnectionGroup]? {
        let graph = LibraryGroupGraph(groups: groups)
        guard graph.canPlace(group.id, under: group.parentId) else { return nil }
        var placed = group
        placed.sortOrder = LibraryOrdering.nextSortOrder(
            after: groups.filter { $0.parentId == group.parentId }.map(\.sortOrder)
        )
        return groups + [placed]
    }

    static func mutatingGroup(
        _ id: UUID,
        in groups: [ConnectionGroup],
        _ mutate: (inout ConnectionGroup) -> Void
    ) -> (groups: [ConnectionGroup], changed: Bool)? {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return nil }
        let stored = groups[index]
        var updated = stored
        mutate(&updated)
        updated.id = id
        if updated.parentId != stored.parentId {
            guard LibraryGroupGraph(groups: groups).canPlace(id, under: updated.parentId) else { return nil }
            updated.sortOrder = LibraryOrdering.nextSortOrder(
                after: groups.filter { $0.parentId == updated.parentId && $0.id != id }.map(\.sortOrder)
            )
        }
        guard updated != stored else { return (groups, false) }
        var result = groups
        result[index] = updated
        return (result, true)
    }

    static func mutatingTag(
        _ id: UUID,
        in tags: [ConnectionTag],
        _ mutate: (inout ConnectionTag) -> Void
    ) -> (tags: [ConnectionTag], changed: Bool)? {
        guard let index = tags.firstIndex(where: { $0.id == id }) else { return nil }
        let stored = tags[index]
        var updated = stored
        mutate(&updated)
        updated.id = id
        guard updated != stored else { return (tags, false) }
        var result = tags
        result[index] = updated
        return (result, true)
    }

    static func reorderingGroups(_ orderedIds: [UUID], in groups: [ConnectionGroup]) -> (groups: [ConnectionGroup], changed: [UUID]) {
        let ranks = LibraryOrdering.ranks(for: orderedIds)
        var changed: [UUID] = []
        let result = groups.map { group -> ConnectionGroup in
            guard let rank = ranks[group.id], rank != group.sortOrder else { return group }
            var updated = group
            updated.sortOrder = rank
            changed.append(group.id)
            return updated
        }
        return (result, changed)
    }

    static func deletingGroup(
        _ groupId: UUID,
        groups: [ConnectionGroup],
        connections: [DatabaseConnection]
    ) -> GroupLibraryChange {
        let graph = LibraryGroupGraph(groups: groups)
        let removed = graph.descendantIds(of: groupId).union([groupId])
        let remainingGroups = groups.filter { !removed.contains($0.id) }
        let remainingGroupIds = Set(remainingGroups.map(\.id))
        let orphaned = connections.filter { connection in
            connection.groupId.map(removed.contains) ?? false
        }
        let placed = moving(
            orphaned.map(\.id),
            toGroup: nil,
            in: connections,
            validGroupIds: remainingGroupIds
        )
        return GroupLibraryChange(
            groups: remainingGroups,
            connections: placed.connections,
            changedGroupIds: [],
            removedGroupIds: groups.map(\.id).filter(removed.contains),
            changedConnectionIds: placed.changedConnectionIds
        )
    }

    static func deletingTag(
        _ tagId: UUID,
        tags: [ConnectionTag],
        connections: [DatabaseConnection]
    ) -> TagLibraryChange? {
        guard let tag = tags.first(where: { $0.id == tagId }), !tag.isPreset else { return nil }
        let stripped = applying(to: connections) { connection in
            connection.tagIds.removeAll { $0 == tagId }
        }
        return TagLibraryChange(
            tags: tags.filter { $0.id != tagId },
            connections: stripped.connections,
            removedTagId: tagId,
            changedConnectionIds: stripped.changedConnectionIds
        )
    }

    static func tagDeletionRequest(
        _ tagId: UUID,
        tags: [ConnectionTag],
        connections: [DatabaseConnection]
    ) -> TagDeletionRequest? {
        guard let change = deletingTag(tagId, tags: tags, connections: connections),
              let tag = tags.first(where: { $0.id == tagId }) else { return nil }
        return TagDeletionRequest(tag: tag, connectionCount: change.changedConnectionIds.count)
    }

    static func tagUsageCounts(in connections: [DatabaseConnection]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for connection in connections {
            for tagId in Set(connection.tagIds) {
                counts[tagId, default: 0] += 1
            }
        }
        return counts
    }

    private static func applying(
        to connections: [DatabaseConnection],
        _ mutate: (inout DatabaseConnection) -> Void
    ) -> ConnectionLibraryChange {
        var changed: [UUID] = []
        let result = connections.map { connection -> DatabaseConnection in
            var updated = connection
            mutate(&updated)
            if updated != connection {
                changed.append(connection.id)
            }
            return updated
        }
        return ConnectionLibraryChange(connections: result, changedConnectionIds: changed)
    }
}
