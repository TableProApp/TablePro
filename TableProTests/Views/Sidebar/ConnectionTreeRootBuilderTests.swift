//
//  ConnectionTreeRootBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ConnectionTreeRootBuilder")
struct ConnectionTreeRootBuilderTests {
    private func connection(
        _ name: String,
        group: UUID? = nil,
        sortOrder: Int = 0,
        host: String = "localhost",
        tags: [UUID] = []
    ) -> DatabaseConnection {
        var made = DatabaseConnection(id: UUID(), name: name)
        made.groupId = group
        made.sortOrder = sortOrder
        made.host = host
        made.tagIds = tags
        return made
    }

    @Test("A connection in no folder sits at the top level")
    func ungroupedAtRoot() {
        let alone = connection("alone")
        let layout = ConnectionTreeRootBuilder.layout(groups: [], connections: [alone])
        #expect(layout.roots == [.connection(alone.id)])
        #expect(layout.childrenByGroup.isEmpty)
    }

    @Test("A folder holds its own connections and nothing else")
    func groupHoldsItsConnections() {
        let group = ConnectionGroup(name: "Prod")
        let inside = connection("inside", group: group.id)
        let outside = connection("outside")

        let layout = ConnectionTreeRootBuilder.layout(groups: [group], connections: [inside, outside])
        #expect(layout.roots == [.group(group), .connection(outside.id)])
        #expect(layout.children(ofGroup: group.id) == [.connection(inside.id)])
    }

    @Test("A nested folder is reachable through its parent, not from the root")
    func nestedGroup() {
        let parent = ConnectionGroup(name: "Cloud")
        let child = ConnectionGroup(name: "EU", parentId: parent.id)
        let deep = connection("deep", group: child.id)

        let layout = ConnectionTreeRootBuilder.layout(groups: [parent, child], connections: [deep])
        #expect(layout.roots == [.group(parent)])
        #expect(layout.children(ofGroup: parent.id) == [.group(child)])
        #expect(layout.children(ofGroup: child.id) == [.connection(deep.id)])
    }

    @Test("A connection whose folder no longer exists comes back to the top level")
    func orphanedConnectionIsRooted() {
        let orphan = connection("orphan", group: UUID())
        let layout = ConnectionTreeRootBuilder.layout(groups: [], connections: [orphan])
        #expect(layout.roots == [.connection(orphan.id)])
    }

    @Test("Two folders that made each other their parent both stay visible")
    func cyclicGroupsStayVisible() {
        let first = ConnectionGroup(id: UUID(), name: "A", sortOrder: 0)
        let second = ConnectionGroup(id: UUID(), name: "B", parentId: first.id, sortOrder: 1)
        var cyclicFirst = first
        cyclicFirst.parentId = second.id
        let inside = connection("inside", group: second.id)

        let layout = ConnectionTreeRootBuilder.layout(groups: [cyclicFirst, second], connections: [inside])
        let rootGroupIds = layout.roots.compactMap { kind -> UUID? in
            guard case .group(let group) = kind else { return nil }
            return group.id
        }
        #expect(rootGroupIds.contains(first.id))
        #expect(rootGroupIds.contains(second.id))
        #expect(layout.children(ofGroup: second.id) == [.connection(inside.id)])
    }

    @Test("Search keeps a folder only while something inside it still matches")
    func searchFiltersFolders() {
        let group = ConnectionGroup(name: "Prod")
        let matching = connection("orders-db", group: group.id)
        let other = connection("billing-db", group: group.id)
        let elsewhere = connection("orders-cache")

        let layout = ConnectionTreeRootBuilder.layout(
            groups: [group],
            connections: [matching, other, elsewhere],
            searchText: "orders"
        )
        #expect(layout.roots == [.group(group), .connection(elsewhere.id)])
        #expect(layout.children(ofGroup: group.id) == [.connection(matching.id)])
    }

    @Test("Search matches the host as well as the name")
    func searchMatchesHost() {
        let byHost = connection("anything", host: "db.internal")
        let layout = ConnectionTreeRootBuilder.layout(groups: [], connections: [byHost], searchText: "internal")
        #expect(layout.roots == [.connection(byHost.id)])
    }

    @Test("A folder whose every connection is filtered out disappears with them")
    func emptyFolderDisappears() {
        let group = ConnectionGroup(name: "Prod")
        let hidden = connection("billing", group: group.id)
        let layout = ConnectionTreeRootBuilder.layout(groups: [group], connections: [hidden], searchText: "orders")
        #expect(layout.roots.isEmpty)
    }

    @Test("A tag filter narrows the tree the same way search does")
    func tagFilterNarrows() {
        let tag = UUID()
        let tagged = connection("tagged", tags: [tag])
        let untagged = connection("untagged")

        let layout = ConnectionTreeRootBuilder.layout(
            groups: [],
            connections: [tagged, untagged],
            tagFilter: TagFilter(selectedIds: [tag])
        )
        #expect(layout.roots == [.connection(tagged.id)])
    }

    @Test("Display order walks folders in place, which is what the arrow keys follow")
    func displayOrderWalksFolders() {
        let group = ConnectionGroup(name: "Prod", sortOrder: 0)
        let first = connection("first", group: group.id, sortOrder: 0)
        let second = connection("second", group: group.id, sortOrder: 1)
        let loose = connection("loose", sortOrder: 0)

        let layout = ConnectionTreeRootBuilder.layout(groups: [group], connections: [first, second, loose])
        #expect(layout.connectionIdsInDisplayOrder == [first.id, second.id, loose.id])
    }

    @Test("Node ids tell a folder and a connection apart")
    func nodeIdsAreDistinct() {
        let shared = UUID()
        let group = ConnectionGroup(id: shared, name: "Prod")
        #expect(
            ConnectionTreeRootBuilder.nodeID(for: .group(group))
                != ConnectionTreeRootBuilder.nodeID(for: .connection(shared))
        )
    }

    @Test("Nothing saved is an empty tree, not a crash")
    func emptyInput() {
        let layout = ConnectionTreeRootBuilder.layout(groups: [], connections: [])
        #expect(layout == .empty)
        #expect(layout.connectionIdsInDisplayOrder.isEmpty)
    }
}
