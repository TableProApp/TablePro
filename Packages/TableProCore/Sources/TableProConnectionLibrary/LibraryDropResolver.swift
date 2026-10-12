import Foundation

public enum LibraryDragItem: Hashable, Sendable {
    case connection(UUID, section: LibrarySectionKind)
    case group(UUID)
}

public enum LibraryDropTarget: Hashable, Sendable {
    case section(LibrarySectionKind, childIndex: Int?)
    case group(UUID, childIndex: Int?)
}

public enum LibraryDropOperation: Hashable, Sendable {
    case moveConnections([UUID], toGroup: UUID?, before: UUID?)
    case moveGroups([UUID], toParent: UUID?, before: UUID?)
    case addFavorites([UUID], before: UUID?)
    case reorderFavorites([UUID], before: UUID?)
}

public struct LibraryDropResolution: Hashable, Sendable {
    public let operation: LibraryDropOperation
    public let target: LibraryDropTarget

    public init(operation: LibraryDropOperation, target: LibraryDropTarget) {
        self.operation = operation
        self.target = target
    }
}

public enum LibraryDropResolver {
    public static func resolve<Connection: LibraryConnectionRepresentable>(
        items: [LibraryDragItem],
        target: LibraryDropTarget,
        sortMode: LibrarySortMode,
        graph: LibraryGroupGraph,
        connections: [UUID: Connection],
        outline: LibraryOutline
    ) -> LibraryDropResolution? {
        let connectionIds = unique(items.compactMap { item -> UUID? in
            guard case .connection(let id, _) = item else { return nil }
            return id
        })
        let groupIds = unique(items.compactMap { item -> UUID? in
            guard case .group(let id) = item else { return nil }
            return id
        })
        guard connectionIds.isEmpty != groupIds.isEmpty else { return nil }
        let fromSavedSections = items.allSatisfy { item in
            guard case .connection(_, let section) = item else { return true }
            return section.acceptsSavedConnections
        }
        guard fromSavedSections, connectionIds.allSatisfy({ connections[$0] != nil }) else { return nil }

        switch target {
        case .section(.favorites, let childIndex):
            guard groupIds.isEmpty else { return nil }
            return favoritesDrop(
                items: items,
                ids: connectionIds,
                childIndex: childIndex,
                sortMode: sortMode,
                connections: connections,
                outline: outline
            )
        case .section(.connections, let childIndex):
            return parentDrop(
                parentId: nil,
                childIndex: childIndex,
                siblings: outline.section(.connections)?.nodes ?? [],
                connectionIds: connectionIds,
                groupIds: groupIds,
                sortMode: sortMode,
                graph: graph,
                connections: connections
            )
        case .group(let groupId, let childIndex):
            guard graph.contains(groupId) else { return nil }
            return parentDrop(
                parentId: groupId,
                childIndex: childIndex,
                siblings: groupNode(groupId, in: outline.section(.connections)?.nodes ?? [])?.children ?? [],
                connectionIds: connectionIds,
                groupIds: groupIds,
                sortMode: sortMode,
                graph: graph,
                connections: connections
            )
        case .section:
            return nil
        }
    }

    private static func favoritesDrop<Connection: LibraryConnectionRepresentable>(
        items: [LibraryDragItem],
        ids: [UUID],
        childIndex: Int?,
        sortMode: LibrarySortMode,
        connections: [UUID: Connection],
        outline: LibraryOutline
    ) -> LibraryDropResolution? {
        let placesAtIndex = sortMode == .manual && childIndex != nil
        let favorites = outline.connectionIds(in: .favorites)
        let before = placesAtIndex ? firstId(in: favorites, from: childIndex ?? 0, excluding: Set(ids)) : nil
        let allFromFavorites = items.allSatisfy { item in
            guard case .connection(_, let section) = item else { return false }
            return section == .favorites
        }

        if allFromFavorites {
            guard placesAtIndex else { return nil }
            return LibraryDropResolution(
                operation: .reorderFavorites(ids, before: before),
                target: .section(.favorites, childIndex: childIndex)
            )
        }

        let allAlreadyFavorite = ids.allSatisfy { connections[$0]?.isFavorite == true }
        guard placesAtIndex || !allAlreadyFavorite else { return nil }
        return LibraryDropResolution(
            operation: .addFavorites(ids, before: before),
            target: .section(.favorites, childIndex: placesAtIndex ? childIndex : nil)
        )
    }

    private static func parentDrop<Connection: LibraryConnectionRepresentable>(
        parentId: UUID?,
        childIndex: Int?,
        siblings: [LibraryNode],
        connectionIds: [UUID],
        groupIds: [UUID],
        sortMode: LibrarySortMode,
        graph: LibraryGroupGraph,
        connections: [UUID: Connection]
    ) -> LibraryDropResolution? {
        let placesAtIndex = sortMode == .manual && childIndex != nil
        let dropOnTarget: LibraryDropTarget = parentId.map { .group($0, childIndex: nil) }
            ?? .section(.connections, childIndex: nil)
        let indexedTarget: LibraryDropTarget = parentId.map { .group($0, childIndex: childIndex) }
            ?? .section(.connections, childIndex: childIndex)

        if !groupIds.isEmpty {
            guard groupIds.allSatisfy({ graph.canPlace($0, under: parentId) }) else { return nil }
            if placesAtIndex {
                let siblingGroups = siblings.compactMap(groupId(of:))
                let before = firstId(in: siblingGroups, from: groupPosition(childIndex ?? 0, in: siblings), excluding: Set(groupIds))
                return LibraryDropResolution(
                    operation: .moveGroups(groupIds, toParent: parentId, before: before),
                    target: indexedTarget
                )
            }
            guard !groupIds.allSatisfy({ graph.parentId(of: $0) == parentId }) else { return nil }
            return LibraryDropResolution(
                operation: .moveGroups(groupIds, toParent: parentId, before: nil),
                target: dropOnTarget
            )
        }

        if placesAtIndex {
            let siblingConnections = siblings.compactMap(connectionId(of:))
            let position = connectionPosition(childIndex ?? 0, in: siblings)
            let before = firstId(in: siblingConnections, from: position, excluding: Set(connectionIds))
            return LibraryDropResolution(
                operation: .moveConnections(connectionIds, toGroup: parentId, before: before),
                target: indexedTarget
            )
        }
        let alreadyThere = connectionIds.allSatisfy { id in
            let current = connections[id]?.groupId.flatMap { graph.contains($0) ? $0 : nil }
            return current == parentId
        }
        guard !alreadyThere else { return nil }
        return LibraryDropResolution(
            operation: .moveConnections(connectionIds, toGroup: parentId, before: nil),
            target: dropOnTarget
        )
    }

    private static func groupNode(_ id: UUID, in nodes: [LibraryNode]) -> LibraryNode? {
        for node in nodes {
            guard case .group(let nodeId, let children, _) = node else { continue }
            if nodeId == id { return node }
            if let found = groupNode(id, in: children) { return found }
        }
        return nil
    }

    private static func groupId(of node: LibraryNode) -> UUID? {
        guard case .group(let id, _, _) = node else { return nil }
        return id
    }

    private static func connectionId(of node: LibraryNode) -> UUID? {
        guard case .connection(let id) = node else { return nil }
        return id
    }

    private static func groupPosition(_ childIndex: Int, in siblings: [LibraryNode]) -> Int {
        siblings.prefix(max(0, childIndex)).filter { groupId(of: $0) != nil }.count
    }

    private static func connectionPosition(_ childIndex: Int, in siblings: [LibraryNode]) -> Int {
        siblings.prefix(max(0, childIndex)).filter { connectionId(of: $0) != nil }.count
    }

    private static func firstId(in ids: [UUID], from position: Int, excluding: Set<UUID>) -> UUID? {
        guard position < ids.count else { return nil }
        return ids[max(0, position)...].first { !excluding.contains($0) }
    }

    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
