//
//  ConnectionGroupTree.swift
//  TablePro
//

import Foundation

enum ConnectionGroupTreeNode: Identifiable {
    case group(ConnectionGroup, children: [ConnectionGroupTreeNode])
    case connection(DatabaseConnection)

    var id: String {
        switch self {
        case .group(let g, _): "group-\(g.id)"
        case .connection(let c): "conn-\(c.id)"
        }
    }
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
            .filter { $0.parentId == nil || ($0.parentId.flatMap { validGroupIds.contains($0) } != true) }
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
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
    return 1 + (children.map { maxDescendantDepth(groupId: $0.id, groups: groups) }.max() ?? 0)
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

// MARK: - Indexed Tree (O(G+C))

struct GroupTreeIndices {
    var connectionCountByGroup: [UUID: Int] = [:]
    var depthByGroup: [UUID: Int] = [:]
    var maxDescendantDepthByGroup: [UUID: Int] = [:]
}

private struct GroupTreeIndex {
    let validGroupIds: Set<UUID>
    let childrenByParentId: [UUID?: [ConnectionGroup]]
    let connectionsByGroupId: [UUID: [DatabaseConnection]]
}

private func sortGroups(_ groups: [ConnectionGroup]) -> [ConnectionGroup] {
    groups.sorted {
        $0.sortOrder != $1.sortOrder
            ? $0.sortOrder < $1.sortOrder
            : $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
}

private func sortConnections(_ connections: [DatabaseConnection]) -> [DatabaseConnection] {
    connections.sorted {
        $0.sortOrder != $1.sortOrder
            ? $0.sortOrder < $1.sortOrder
            : $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
}

private func buildGroupTreeIndex(groups: [ConnectionGroup], connections: [DatabaseConnection]) -> GroupTreeIndex {
    let validGroupIds = Set(groups.map(\.id))

    var childrenByParentId: [UUID?: [ConnectionGroup]] = [:]
    for group in groups {
        let parentKey = group.parentId.flatMap { validGroupIds.contains($0) ? $0 : nil }
        childrenByParentId[parentKey, default: []].append(group)
    }
    for key in childrenByParentId.keys {
        if let levelGroups = childrenByParentId[key] {
            childrenByParentId[key] = sortGroups(levelGroups)
        }
    }

    var connectionsByGroupId: [UUID: [DatabaseConnection]] = [:]
    for connection in connections {
        guard let groupId = connection.groupId, validGroupIds.contains(groupId) else { continue }
        connectionsByGroupId[groupId, default: []].append(connection)
    }
    for groupId in connectionsByGroupId.keys {
        if let groupConnections = connectionsByGroupId[groupId] {
            connectionsByGroupId[groupId] = sortConnections(groupConnections)
        }
    }

    return GroupTreeIndex(
        validGroupIds: validGroupIds,
        childrenByParentId: childrenByParentId,
        connectionsByGroupId: connectionsByGroupId
    )
}

func buildGroupTreeIndexed(
    groups: [ConnectionGroup],
    connections: [DatabaseConnection],
    maxDepth: Int = 3
) -> [ConnectionGroupTreeNode] {
    let index = buildGroupTreeIndex(groups: groups, connections: connections)
    return buildGroupTreeIndexedLevel(
        parentId: nil,
        currentDepth: 0,
        maxDepth: maxDepth,
        index: index,
        connections: connections
    )
}

private func buildGroupTreeIndexedLevel(
    parentId: UUID?,
    currentDepth: Int,
    maxDepth: Int,
    index: GroupTreeIndex,
    connections: [DatabaseConnection]
) -> [ConnectionGroupTreeNode] {
    var items: [ConnectionGroupTreeNode] = []
    let levelGroups = index.childrenByParentId[parentId] ?? []

    for group in levelGroups {
        var children: [ConnectionGroupTreeNode] = []
        if currentDepth < maxDepth {
            children = buildGroupTreeIndexedLevel(
                parentId: group.id,
                currentDepth: currentDepth + 1,
                maxDepth: maxDepth,
                index: index,
                connections: connections
            )
        }
        for conn in index.connectionsByGroupId[group.id] ?? [] {
            children.append(.connection(conn))
        }
        items.append(.group(group, children: children))
    }

    if parentId == nil {
        let ungrouped = sortConnections(connections.filter { conn in
            guard let groupId = conn.groupId else { return true }
            return !index.validGroupIds.contains(groupId)
        })
        for conn in ungrouped {
            items.append(.connection(conn))
        }
    }

    return items
}

func buildGroupTreeWithIndices(
    groups: [ConnectionGroup],
    connections: [DatabaseConnection],
    maxDepth: Int = 3
) -> (tree: [ConnectionGroupTreeNode], indices: GroupTreeIndices) {
    let index = buildGroupTreeIndex(groups: groups, connections: connections)
    let tree = buildGroupTreeIndexedLevel(
        parentId: nil,
        currentDepth: 0,
        maxDepth: maxDepth,
        index: index,
        connections: connections
    )
    return (tree, computeGroupTreeIndices(from: index, groups: groups, connections: connections))
}

func computeGroupTreeIndices(groups: [ConnectionGroup], connections: [DatabaseConnection]) -> GroupTreeIndices {
    computeGroupTreeIndices(
        from: buildGroupTreeIndex(groups: groups, connections: connections),
        groups: groups,
        connections: connections
    )
}

private func computeGroupTreeIndices(
    from index: GroupTreeIndex,
    groups: [ConnectionGroup],
    connections: [DatabaseConnection]
) -> GroupTreeIndices {
    var result = GroupTreeIndices()

    var depthByGroup: [UUID: Int] = [:]
    var visitedDepth: Set<UUID> = []
    var queue: [(UUID, Int)] = []
    let roots = index.childrenByParentId[nil] ?? []
    for root in roots where !visitedDepth.contains(root.id) {
        visitedDepth.insert(root.id)
        depthByGroup[root.id] = 1
        queue.append((root.id, 1))
    }
    var queueIndex = 0
    while queueIndex < queue.count {
        let (currentId, currentDepth) = queue[queueIndex]
        queueIndex += 1
        let children = index.childrenByParentId[currentId] ?? []
        for child in children where !visitedDepth.contains(child.id) {
            visitedDepth.insert(child.id)
            depthByGroup[child.id] = currentDepth + 1
            queue.append((child.id, currentDepth + 1))
        }
    }

    var maxDepthByGroup: [UUID: Int] = [:]
    var connectionCountByGroup: [UUID: Int] = [:]
    for root in roots {
        _ = aggregateSubtree(
            groupId: root.id,
            visited: [],
            index: index,
            maxDepthByGroup: &maxDepthByGroup,
            connectionCountByGroup: &connectionCountByGroup
        )
    }

    for group in groups {
        result.depthByGroup[group.id] = depthByGroup[group.id]
            ?? depthOf(groupId: group.id, groups: groups)
        result.maxDescendantDepthByGroup[group.id] = maxDepthByGroup[group.id]
            ?? maxDescendantDepth(groupId: group.id, groups: groups)
        result.connectionCountByGroup[group.id] = connectionCountByGroup[group.id]
            ?? connectionCount(in: group.id, connections: connections, groups: groups)
    }

    return result
}

private struct SubtreeAggregate {
    var maxDescendantDepth: Int
    var connectionCount: Int
}

private func aggregateSubtree(
    groupId: UUID,
    visited: Set<UUID>,
    index: GroupTreeIndex,
    maxDepthByGroup: inout [UUID: Int],
    connectionCountByGroup: inout [UUID: Int]
) -> SubtreeAggregate {
    var nextVisited = visited
    nextVisited.insert(groupId)

    let children = index.childrenByParentId[groupId] ?? []
    var maxChildDescendantDepth = 0
    var subtreeCount = index.connectionsByGroupId[groupId]?.count ?? 0

    for child in children where !visited.contains(child.id) {
        let childAggregate = aggregateSubtree(
            groupId: child.id,
            visited: nextVisited,
            index: index,
            maxDepthByGroup: &maxDepthByGroup,
            connectionCountByGroup: &connectionCountByGroup
        )
        maxChildDescendantDepth = max(maxChildDescendantDepth, childAggregate.maxDescendantDepth)
        subtreeCount += childAggregate.connectionCount
    }

    let maxDescendantDepthValue = children.isEmpty ? 0 : 1 + maxChildDescendantDepth
    let result = SubtreeAggregate(
        maxDescendantDepth: maxDescendantDepthValue,
        connectionCount: subtreeCount
    )
    maxDepthByGroup[groupId] = result.maxDescendantDepth
    connectionCountByGroup[groupId] = result.connectionCount
    return result
}
