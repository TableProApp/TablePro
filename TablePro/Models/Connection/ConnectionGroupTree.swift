//
//  ConnectionGroupTree.swift
//  TablePro
//

import Foundation

enum ConnectionGroupTreeNode: Identifiable, Hashable {
    case group(ConnectionGroup, children: [ConnectionGroupTreeNode])
    case connection(DatabaseConnection)

    var id: String {
        switch self {
        case .group(let g, _): "group-\(g.id)"
        case .connection(let c): "conn-\(c.id)"
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Tree Building

func buildGroupTree(
    groups: [ConnectionGroup],
    connections: [DatabaseConnection],
    parentId: UUID?,
    maxDepth: Int = 3,
    currentDepth: Int = 0
) -> [ConnectionGroupTreeNode] {
    var items: [ConnectionGroupTreeNode] = []

    let validGroupIds = Set(groups.map(\.id))

    let levelGroups: [ConnectionGroup]
    if parentId == nil {
        levelGroups = groups
            .filter { $0.parentId == nil || !validGroupIds.contains($0.parentId!) }
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    } else {
        levelGroups = groups
            .filter { $0.parentId == parentId }
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    for group in levelGroups {
        var children: [ConnectionGroupTreeNode] = []
        if currentDepth < maxDepth {
            children = buildGroupTree(
                groups: groups,
                connections: connections,
                parentId: group.id,
                maxDepth: maxDepth,
                currentDepth: currentDepth + 1
            )
        }

        let groupConnections = connections
            .filter { $0.groupId == group.id }
        for conn in groupConnections {
            children.append(.connection(conn))
        }

        items.append(.group(group, children: children))
    }

    if parentId == nil {
        let ungrouped = connections.filter { conn in
            guard let groupId = conn.groupId else { return true }
            return !validGroupIds.contains(groupId)
        }
        for conn in ungrouped {
            items.append(.connection(conn))
        }
    }

    return items
}

// MARK: - Tree Filtering

func filterGroupTree(_ items: [ConnectionGroupTreeNode], searchText: String) -> [ConnectionGroupTreeNode] {
    guard !searchText.isEmpty else { return items }

    return items.compactMap { item in
        switch item {
        case .connection(let conn):
            if conn.name.localizedCaseInsensitiveContains(searchText)
                || conn.host.localizedCaseInsensitiveContains(searchText)
                || conn.database.localizedCaseInsensitiveContains(searchText) {
                return item
            }
            return nil
        case .group(let group, let children):
            if group.name.localizedCaseInsensitiveContains(searchText) {
                return item
            }
            let filteredChildren = filterGroupTree(children, searchText: searchText)
            if !filteredChildren.isEmpty {
                return .group(group, children: filteredChildren)
            }
            return nil
        }
    }
}

// MARK: - Tree Traversal

func flattenVisibleConnections(
    tree: [ConnectionGroupTreeNode],
    expandedGroupIds: Set<UUID>
) -> [DatabaseConnection] {
    var result: [DatabaseConnection] = []
    for item in tree {
        switch item {
        case .connection(let conn):
            result.append(conn)
        case .group(let group, let children):
            if expandedGroupIds.contains(group.id) {
                result.append(contentsOf: flattenVisibleConnections(tree: children, expandedGroupIds: expandedGroupIds))
            }
        }
    }
    return result
}

func collectAllDescendantGroupIds(groupId: UUID, groups: [ConnectionGroup], visited: Set<UUID> = []) -> Set<UUID> {
    var result = Set<UUID>()
    let directChildren = groups.filter { $0.parentId == groupId }
    for child in directChildren where !visited.contains(child.id) {
        result.insert(child.id)
        result.formUnion(collectAllDescendantGroupIds(groupId: child.id, groups: groups, visited: visited.union(result).union([groupId])))
    }
    return result
}

func wouldCreateCircle(movingGroupId: UUID, toParentId: UUID?, groups: [ConnectionGroup]) -> Bool {
    guard let targetId = toParentId else { return false }
    if targetId == movingGroupId { return true }
    let descendants = collectAllDescendantGroupIds(groupId: movingGroupId, groups: groups)
    return descendants.contains(targetId)
}

func depthOf(groupId: UUID?, groups: [ConnectionGroup], visited: Set<UUID> = []) -> Int {
    guard let gid = groupId else { return 0 }
    guard !visited.contains(gid) else { return 0 }
    guard let group = groups.first(where: { $0.id == gid }) else { return 0 }
    return 1 + depthOf(groupId: group.parentId, groups: groups, visited: visited.union([gid]))
}

func maxDescendantDepth(groupId: UUID, groups: [ConnectionGroup]) -> Int {
    let children = groups.filter { $0.parentId == groupId }
    if children.isEmpty { return 0 }
    return 1 + children.map { maxDescendantDepth(groupId: $0.id, groups: groups) }.max()!
}

func connectionCount(in groupId: UUID, connections: [DatabaseConnection], groups: [ConnectionGroup]) -> Int {
    let directCount = connections.filter { $0.groupId == groupId }.count
    let descendants = collectAllDescendantGroupIds(groupId: groupId, groups: groups)
    let descendantCount = connections.filter { conn in
        guard let gid = conn.groupId else { return false }
        return descendants.contains(gid)
    }.count
    return directCount + descendantCount
}
