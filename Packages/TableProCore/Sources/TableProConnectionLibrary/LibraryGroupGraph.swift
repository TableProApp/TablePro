import Foundation

public struct LibraryGroupGraph: Sendable {
    public static let maxNestingDepth = 3

    public struct Entry: Hashable, Sendable {
        public let id: UUID
        public let name: String
        public let parentId: UUID?
        public let sortOrder: Int
    }

    public struct FlatEntry: Hashable, Sendable {
        public let id: UUID
        public let depth: Int
    }

    public let entries: [UUID: Entry]
    private let childrenByParent: [UUID?: [UUID]]

    public init<Group: LibraryGroupRepresentable>(groups: [Group]) {
        var raw: [UUID: Entry] = [:]
        for group in groups where raw[group.id] == nil {
            raw[group.id] = Entry(id: group.id, name: group.name, parentId: group.parentId, sortOrder: group.sortOrder)
        }
        let cyclic = Self.cyclicIds(in: raw)
        var resolved: [UUID: Entry] = [:]
        for (id, entry) in raw {
            let parentIsReachable = entry.parentId.map { raw[$0] != nil && !cyclic.contains(id) } ?? false
            resolved[id] = Entry(
                id: id,
                name: entry.name,
                parentId: parentIsReachable ? entry.parentId : nil,
                sortOrder: entry.sortOrder
            )
        }
        var children: [UUID?: [UUID]] = [:]
        for entry in resolved.values {
            children[entry.parentId, default: []].append(entry.id)
        }
        entries = resolved
        childrenByParent = children
    }

    public func contains(_ id: UUID) -> Bool {
        entries[id] != nil
    }

    public func parentId(of id: UUID) -> UUID? {
        entries[id]?.parentId
    }

    public func childIds(of parentId: UUID?) -> [UUID] {
        childrenByParent[parentId] ?? []
    }

    public func sortedChildIds(of parentId: UUID?, mode: LibrarySortMode) -> [UUID] {
        childIds(of: parentId)
            .compactMap { entries[$0] }
            .sorted { LibrarySorting.groupPrecedes($0, $1, mode: mode) }
            .map(\.id)
    }

    public func depth(of id: UUID?) -> Int {
        guard let id else { return 0 }
        var depth = 0
        var current: UUID? = id
        var visited: Set<UUID> = []
        while let node = current, let entry = entries[node], visited.insert(node).inserted {
            depth += 1
            current = entry.parentId
        }
        return depth
    }

    public func maxDescendantDepth(of id: UUID) -> Int {
        maxDescendantDepth(of: id, visited: [])
    }

    private func maxDescendantDepth(of id: UUID, visited: Set<UUID>) -> Int {
        let nextVisited = visited.union([id])
        let children = childIds(of: id).filter { !nextVisited.contains($0) }
        guard !children.isEmpty else { return 0 }
        return 1 + (children.map { maxDescendantDepth(of: $0, visited: nextVisited) }.max() ?? 0)
    }

    public func descendantIds(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = []
        var stack = childIds(of: id)
        while let next = stack.popLast() {
            guard next != id, result.insert(next).inserted else { continue }
            stack.append(contentsOf: childIds(of: next))
        }
        return result
    }

    public func pathIds(to id: UUID) -> [UUID] {
        var path: [UUID] = []
        var current: UUID? = id
        var visited: Set<UUID> = []
        while let node = current, entries[node] != nil, visited.insert(node).inserted {
            path.insert(node, at: 0)
            current = entries[node]?.parentId
        }
        return path
    }

    public func pathNames(to id: UUID) -> [String] {
        pathIds(to: id).compactMap { entries[$0]?.name }
    }

    public enum PlacementProblem: Sendable {
        case cycle
        case depthExceeded
        case missingParent
    }

    public func placementProblem(_ groupId: UUID, under parentId: UUID?) -> PlacementProblem? {
        if let parentId {
            guard parentId != groupId, !descendantIds(of: groupId).contains(parentId) else { return .cycle }
            guard entries[parentId] != nil else { return .missingParent }
        }
        let subtree = entries[groupId] == nil ? 0 : maxDescendantDepth(of: groupId)
        guard depth(of: parentId) + 1 + subtree <= Self.maxNestingDepth else { return .depthExceeded }
        return nil
    }

    public func canPlace(_ groupId: UUID, under parentId: UUID?) -> Bool {
        placementProblem(groupId, under: parentId) == nil
    }

    public static func cyclicGroupIds<Group: LibraryGroupRepresentable>(in groups: [Group]) -> Set<UUID> {
        var raw: [UUID: Entry] = [:]
        for group in groups where raw[group.id] == nil {
            raw[group.id] = Entry(id: group.id, name: group.name, parentId: group.parentId, sortOrder: group.sortOrder)
        }
        return cyclicIds(in: raw)
    }

    public func canCreateSubgroup(under parentId: UUID) -> Bool {
        entries[parentId] != nil && depth(of: parentId) < Self.maxNestingDepth
    }

    public func flattened(mode: LibrarySortMode = .manual) -> [FlatEntry] {
        var result: [FlatEntry] = []
        var visited: Set<UUID> = []
        func visit(_ parentId: UUID?, depth: Int) {
            for id in sortedChildIds(of: parentId, mode: mode) where visited.insert(id).inserted {
                result.append(FlatEntry(id: id, depth: depth))
                visit(id, depth: depth + 1)
            }
        }
        visit(nil, depth: 0)
        return result
    }

    private static func cyclicIds(in entries: [UUID: Entry]) -> Set<UUID> {
        var cyclic: Set<UUID> = []
        var acyclic: Set<UUID> = []
        for start in entries.keys {
            var path: [UUID] = []
            var onPath: Set<UUID> = []
            var current: UUID? = start
            while let node = current, let entry = entries[node] {
                if acyclic.contains(node) || cyclic.contains(node) { break }
                if onPath.contains(node) {
                    if let index = path.firstIndex(of: node) {
                        cyclic.formUnion(path[index...])
                    }
                    break
                }
                path.append(node)
                onPath.insert(node)
                current = entry.parentId
            }
            acyclic.formUnion(path.filter { !cyclic.contains($0) })
        }
        return cyclic
    }
}
