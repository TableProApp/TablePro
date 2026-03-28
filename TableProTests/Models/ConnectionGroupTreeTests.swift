//
//  ConnectionGroupTreeTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("ConnectionGroupTree")
struct ConnectionGroupTreeTests {

    // MARK: - Helpers

    private func makeGroup(
        id: UUID = UUID(),
        name: String,
        parentId: UUID? = nil,
        sortOrder: Int = 0
    ) -> ConnectionGroup {
        ConnectionGroup(id: id, name: name, parentId: parentId, sortOrder: sortOrder)
    }

    private func makeConnection(
        id: UUID = UUID(),
        name: String,
        groupId: UUID? = nil,
        host: String = "localhost",
        database: String = ""
    ) -> DatabaseConnection {
        DatabaseConnection(id: id, name: name, host: host, database: database, groupId: groupId)
    }

    private func groupIds(from nodes: [ConnectionGroupTreeNode]) -> [UUID] {
        nodes.compactMap { node in
            if case .group(let g, _) = node { return g.id }
            return nil
        }
    }

    private func connectionIds(from nodes: [ConnectionGroupTreeNode]) -> [UUID] {
        nodes.compactMap { node in
            if case .connection(let c) = node { return c.id }
            return nil
        }
    }

    private func children(of node: ConnectionGroupTreeNode) -> [ConnectionGroupTreeNode] {
        if case .group(_, let children) = node { return children }
        return []
    }

    // MARK: - buildGroupTree

    @Test("Empty inputs produce empty tree")
    func buildGroupTree_emptyInputs() {
        let result = buildGroupTree(groups: [], connections: [], parentId: nil)
        #expect(result.isEmpty)
    }

    @Test("Ungrouped connections appear as top-level connection nodes")
    func buildGroupTree_ungroupedConnections() {
        let c1 = makeConnection(name: "DB1")
        let c2 = makeConnection(name: "DB2")

        let result = buildGroupTree(groups: [], connections: [c1, c2], parentId: nil)

        #expect(result.count == 2)
        let ids = connectionIds(from: result)
        #expect(ids.contains(c1.id))
        #expect(ids.contains(c2.id))
    }

    @Test("Single-level groups contain their connections")
    func buildGroupTree_singleLevelGroups() {
        let gId = UUID()
        let group = makeGroup(id: gId, name: "Production")
        let c1 = makeConnection(name: "Prod DB", groupId: gId)
        let c2 = makeConnection(name: "Local DB")

        let result = buildGroupTree(groups: [group], connections: [c1, c2], parentId: nil)

        #expect(result.count == 2)
        let gIds = groupIds(from: result)
        #expect(gIds.contains(gId))

        let groupNode = result.first { if case .group(let g, _) = $0 { return g.id == gId } else { return false } }!
        let groupChildren = children(of: groupNode)
        let childConnIds = connectionIds(from: groupChildren)
        #expect(childConnIds == [c1.id])

        let topConnIds = connectionIds(from: result)
        #expect(topConnIds == [c2.id])
    }

    @Test("Three-level nested groups produce correct hierarchy")
    func buildGroupTree_threeLevelNesting() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let g1 = makeGroup(id: id1, name: "Level 1")
        let g2 = makeGroup(id: id2, name: "Level 2", parentId: id1)
        let g3 = makeGroup(id: id3, name: "Level 3", parentId: id2)
        let conn = makeConnection(name: "Deep DB", groupId: id3)

        let result = buildGroupTree(groups: [g1, g2, g3], connections: [conn], parentId: nil)

        #expect(result.count == 1)
        let level1Children = children(of: result[0])
        #expect(groupIds(from: level1Children) == [id2])

        let level2Children = children(of: level1Children[0])
        #expect(groupIds(from: level2Children) == [id3])

        let level3Children = children(of: level2Children[0])
        #expect(connectionIds(from: level3Children) == [conn.id])
    }

    @Test("Max depth cap stops recursion at depth 3")
    func buildGroupTree_maxDepthCap() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let id4 = UUID()
        let g1 = makeGroup(id: id1, name: "L1")
        let g2 = makeGroup(id: id2, name: "L2", parentId: id1)
        let g3 = makeGroup(id: id3, name: "L3", parentId: id2)
        let g4 = makeGroup(id: id4, name: "L4", parentId: id3)
        let conn = makeConnection(name: "Deep", groupId: id4)

        let result = buildGroupTree(
            groups: [g1, g2, g3, g4],
            connections: [conn],
            parentId: nil,
            maxDepth: 3
        )

        // L1 -> L2 -> L3 -> (L4 should still appear since depth 0,1,2 are within maxDepth=3)
        let l1Children = children(of: result[0])
        let l2Children = children(of: l1Children[0])
        let l3Children = children(of: l2Children[0])

        // At depth 3, recursion builds children for L3, which finds L4 at currentDepth=3
        // Since currentDepth (3) is NOT < maxDepth (3), L4's children won't recurse further
        // but L4 itself still appears as a group with only its direct connections
        let l3GroupIds = groupIds(from: l3Children)
        #expect(l3GroupIds == [id4])

        // L4 should have the connection but no further nested groups
        let l4Children = children(of: l3Children[0])
        #expect(connectionIds(from: l4Children) == [conn.id])
    }

    @Test("Orphan groups with non-existent parentId are treated as top-level")
    func buildGroupTree_orphanGroups() {
        let orphanGroup = makeGroup(name: "Orphan", parentId: UUID())
        let conn = makeConnection(name: "In orphan", groupId: orphanGroup.id)

        let result = buildGroupTree(groups: [orphanGroup], connections: [conn], parentId: nil)

        #expect(groupIds(from: result) == [orphanGroup.id])
        let groupChildren = children(of: result[0])
        #expect(connectionIds(from: groupChildren) == [conn.id])
    }

    @Test("Orphan connections with non-existent groupId are treated as top-level")
    func buildGroupTree_orphanConnections() {
        let conn = makeConnection(name: "Orphan Conn", groupId: UUID())

        let result = buildGroupTree(groups: [], connections: [conn], parentId: nil)

        #expect(connectionIds(from: result) == [conn.id])
    }

    @Test("Groups are sorted by sortOrder first, then name")
    func buildGroupTree_sorting() {
        let g1 = makeGroup(name: "Beta", sortOrder: 2)
        let g2 = makeGroup(name: "Alpha", sortOrder: 1)
        let g3 = makeGroup(name: "Charlie", sortOrder: 1)

        // g2 and g3 each need a connection to appear in tree
        let c1 = makeConnection(name: "c1", groupId: g1.id)
        let c2 = makeConnection(name: "c2", groupId: g2.id)
        let c3 = makeConnection(name: "c3", groupId: g3.id)

        let result = buildGroupTree(
            groups: [g1, g2, g3],
            connections: [c1, c2, c3],
            parentId: nil
        )

        let names = result.compactMap { node -> String? in
            if case .group(let g, _) = node { return g.name }
            return nil
        }
        // sortOrder 1 first (Alpha, Charlie alphabetically), then sortOrder 2 (Beta)
        #expect(names == ["Alpha", "Charlie", "Beta"])
    }

    // MARK: - filterGroupTree

    @Test("Empty search text returns input unchanged")
    func filterGroupTree_emptySearch() {
        let conn = makeConnection(name: "Test")
        let tree: [ConnectionGroupTreeNode] = [.connection(conn)]

        let result = filterGroupTree(tree, searchText: "")
        #expect(result.count == 1)
    }

    @Test("Search matches connection name returns only matching connections")
    func filterGroupTree_matchesConnectionName() {
        let c1 = makeConnection(name: "Production DB")
        let c2 = makeConnection(name: "Staging DB")
        let tree: [ConnectionGroupTreeNode] = [.connection(c1), .connection(c2)]

        let result = filterGroupTree(tree, searchText: "Production")
        #expect(result.count == 1)
        #expect(connectionIds(from: result) == [c1.id])
    }

    @Test("Search matches group name preserves entire subtree")
    func filterGroupTree_matchesGroupName() {
        let group = makeGroup(name: "Production")
        let conn = makeConnection(name: "mydb")
        let tree: [ConnectionGroupTreeNode] = [
            .group(group, children: [.connection(conn)])
        ]

        let result = filterGroupTree(tree, searchText: "Production")

        #expect(result.count == 1)
        if case .group(let g, let kids) = result[0] {
            #expect(g.id == group.id)
            // Entire subtree preserved when group name matches
            #expect(kids.count == 1)
        } else {
            Issue.record("Expected group node")
        }
    }

    @Test("Search matches nested connection preserves parent chain")
    func filterGroupTree_matchesNestedConnection() {
        let group = makeGroup(name: "Servers")
        let c1 = makeConnection(name: "Production DB")
        let c2 = makeConnection(name: "Staging DB")
        let tree: [ConnectionGroupTreeNode] = [
            .group(group, children: [.connection(c1), .connection(c2)])
        ]

        let result = filterGroupTree(tree, searchText: "Production")

        #expect(result.count == 1)
        if case .group(_, let kids) = result[0] {
            #expect(kids.count == 1)
            #expect(connectionIds(from: kids) == [c1.id])
        } else {
            Issue.record("Expected group node")
        }
    }

    @Test("No matches returns empty result")
    func filterGroupTree_noMatches() {
        let conn = makeConnection(name: "Test DB")
        let tree: [ConnectionGroupTreeNode] = [.connection(conn)]

        let result = filterGroupTree(tree, searchText: "nonexistent")
        #expect(result.isEmpty)
    }

    // MARK: - flattenVisibleConnections

    @Test("All groups expanded returns all connections in depth-first order")
    func flattenVisibleConnections_allExpanded() {
        let gId = UUID()
        let group = makeGroup(id: gId, name: "G")
        let c1 = makeConnection(name: "Inside")
        let c2 = makeConnection(name: "Outside")
        let tree: [ConnectionGroupTreeNode] = [
            .group(group, children: [.connection(c1)]),
            .connection(c2)
        ]

        let result = flattenVisibleConnections(tree: tree, expandedGroupIds: [gId])

        #expect(result.map(\.id) == [c1.id, c2.id])
    }

    @Test("Collapsed group skips its children")
    func flattenVisibleConnections_collapsedGroup() {
        let gId = UUID()
        let group = makeGroup(id: gId, name: "G")
        let c1 = makeConnection(name: "Inside")
        let c2 = makeConnection(name: "Outside")
        let tree: [ConnectionGroupTreeNode] = [
            .group(group, children: [.connection(c1)]),
            .connection(c2)
        ]

        let result = flattenVisibleConnections(tree: tree, expandedGroupIds: [])

        #expect(result.map(\.id) == [c2.id])
    }

    @Test("Nested collapse hides all descendants")
    func flattenVisibleConnections_nestedCollapse() {
        let gOuter = UUID()
        let gInner = UUID()
        let outerGroup = makeGroup(id: gOuter, name: "Outer")
        let innerGroup = makeGroup(id: gInner, name: "Inner")
        let c1 = makeConnection(name: "Deep")
        let c2 = makeConnection(name: "Top")
        let tree: [ConnectionGroupTreeNode] = [
            .group(outerGroup, children: [
                .group(innerGroup, children: [.connection(c1)])
            ]),
            .connection(c2)
        ]

        // Outer collapsed, inner expanded -> still no c1 visible
        let result = flattenVisibleConnections(tree: tree, expandedGroupIds: [gInner])
        #expect(result.map(\.id) == [c2.id])
    }

    // MARK: - collectAllDescendantGroupIds

    @Test("Leaf group with no children returns empty set")
    func collectAllDescendantGroupIds_leaf() {
        let gId = UUID()
        let group = makeGroup(id: gId, name: "Leaf")

        let result = collectAllDescendantGroupIds(groupId: gId, groups: [group])
        #expect(result.isEmpty)
    }

    @Test("Single child returns set containing child")
    func collectAllDescendantGroupIds_singleChild() {
        let parentId = UUID()
        let childId = UUID()
        let parent = makeGroup(id: parentId, name: "Parent")
        let child = makeGroup(id: childId, name: "Child", parentId: parentId)

        let result = collectAllDescendantGroupIds(groupId: parentId, groups: [parent, child])
        #expect(result == [childId])
    }

    @Test("Deep nesting returns all descendants")
    func collectAllDescendantGroupIds_deepNesting() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let g1 = makeGroup(id: id1, name: "G1")
        let g2 = makeGroup(id: id2, name: "G2", parentId: id1)
        let g3 = makeGroup(id: id3, name: "G3", parentId: id2)

        let result = collectAllDescendantGroupIds(groupId: id1, groups: [g1, g2, g3])
        #expect(result == [id2, id3])
    }

    // MARK: - wouldCreateCircle

    @Test("Move to nil parent never creates circle")
    func wouldCreateCircle_nilParent() {
        let gId = UUID()
        let group = makeGroup(id: gId, name: "G")

        #expect(!wouldCreateCircle(movingGroupId: gId, toParentId: nil, groups: [group]))
    }

    @Test("Move to self creates circle")
    func wouldCreateCircle_self() {
        let gId = UUID()
        let group = makeGroup(id: gId, name: "G")

        #expect(wouldCreateCircle(movingGroupId: gId, toParentId: gId, groups: [group]))
    }

    @Test("Move to direct child creates circle")
    func wouldCreateCircle_directChild() {
        let parentId = UUID()
        let childId = UUID()
        let parent = makeGroup(id: parentId, name: "Parent")
        let child = makeGroup(id: childId, name: "Child", parentId: parentId)

        #expect(wouldCreateCircle(movingGroupId: parentId, toParentId: childId, groups: [parent, child]))
    }

    @Test("Move to deep descendant creates circle")
    func wouldCreateCircle_deepDescendant() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let g1 = makeGroup(id: id1, name: "G1")
        let g2 = makeGroup(id: id2, name: "G2", parentId: id1)
        let g3 = makeGroup(id: id3, name: "G3", parentId: id2)

        #expect(wouldCreateCircle(movingGroupId: id1, toParentId: id3, groups: [g1, g2, g3]))
    }

    @Test("Move to sibling does not create circle")
    func wouldCreateCircle_sibling() {
        let id1 = UUID()
        let id2 = UUID()
        let g1 = makeGroup(id: id1, name: "G1")
        let g2 = makeGroup(id: id2, name: "G2")

        #expect(!wouldCreateCircle(movingGroupId: id1, toParentId: id2, groups: [g1, g2]))
    }

    @Test("Move to unrelated group does not create circle")
    func wouldCreateCircle_unrelated() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let g1 = makeGroup(id: id1, name: "G1")
        let g2 = makeGroup(id: id2, name: "G2", parentId: id1)
        let g3 = makeGroup(id: id3, name: "G3")

        #expect(!wouldCreateCircle(movingGroupId: id1, toParentId: id3, groups: [g1, g2, g3]))
    }

    // MARK: - depthOf

    @Test("nil groupId returns depth 0")
    func depthOf_nilGroupId() {
        #expect(depthOf(groupId: nil, groups: []) == 0)
    }

    @Test("Top-level group returns depth 1")
    func depthOf_topLevel() {
        let gId = UUID()
        let group = makeGroup(id: gId, name: "Top")

        #expect(depthOf(groupId: gId, groups: [group]) == 1)
    }

    @Test("Nested group at depth 3 returns 3")
    func depthOf_nestedDepth3() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let g1 = makeGroup(id: id1, name: "L1")
        let g2 = makeGroup(id: id2, name: "L2", parentId: id1)
        let g3 = makeGroup(id: id3, name: "L3", parentId: id2)

        #expect(depthOf(groupId: id3, groups: [g1, g2, g3]) == 3)
    }

    // MARK: - connectionCount

    @Test("Direct connections only returns correct count")
    func connectionCount_directOnly() {
        let gId = UUID()
        let group = makeGroup(id: gId, name: "G")
        let c1 = makeConnection(name: "C1", groupId: gId)
        let c2 = makeConnection(name: "C2", groupId: gId)
        let c3 = makeConnection(name: "C3")

        let count = connectionCount(in: gId, connections: [c1, c2, c3], groups: [group])
        #expect(count == 2)
    }

    @Test("Nested groups include all descendant connections")
    func connectionCount_withNestedGroups() {
        let parentId = UUID()
        let childId = UUID()
        let parent = makeGroup(id: parentId, name: "Parent")
        let child = makeGroup(id: childId, name: "Child", parentId: parentId)
        let c1 = makeConnection(name: "In parent", groupId: parentId)
        let c2 = makeConnection(name: "In child", groupId: childId)
        let c3 = makeConnection(name: "Ungrouped")

        let count = connectionCount(in: parentId, connections: [c1, c2, c3], groups: [parent, child])
        #expect(count == 2)
    }

    // MARK: - Cycle Guard

    @Test("Cyclic parentId data does not cause infinite recursion in collectAllDescendantGroupIds")
    func collectAllDescendantGroupIds_cyclicData() {
        let idA = UUID()
        let idB = UUID()
        let a = ConnectionGroup(id: idA, name: "A", parentId: idB)
        let b = ConnectionGroup(id: idB, name: "B", parentId: idA)

        let result = collectAllDescendantGroupIds(groupId: idA, groups: [a, b])
        #expect(result.count <= 2)
    }

    @Test("Cyclic parentId data does not cause infinite recursion in depthOf")
    func depthOf_cyclicData() {
        let idA = UUID()
        let idB = UUID()
        let a = ConnectionGroup(id: idA, name: "A", parentId: idB)
        let b = ConnectionGroup(id: idB, name: "B", parentId: idA)

        let depth = depthOf(groupId: idA, groups: [a, b])
        #expect(depth <= 2)
    }
}
