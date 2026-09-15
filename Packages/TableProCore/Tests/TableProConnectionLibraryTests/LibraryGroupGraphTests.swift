import Foundation
@testable import TableProConnectionLibrary
import Testing

@Suite("Library group graph")
struct LibraryGroupGraphTests {
    @Test("Depth counts from the root")
    func depth() {
        let root = FixtureGroup(name: "Root")
        let child = FixtureGroup(name: "Child", parentId: root.id)
        let graph = LibraryGroupGraph(groups: [root, child])
        #expect(graph.depth(of: nil) == 0)
        #expect(graph.depth(of: root.id) == 1)
        #expect(graph.depth(of: child.id) == 2)
    }

    @Test("A group cannot move into itself or its own subtree")
    func preventsCycles() {
        let root = FixtureGroup(name: "Root")
        let child = FixtureGroup(name: "Child", parentId: root.id)
        let graph = LibraryGroupGraph(groups: [root, child])
        #expect(!graph.canPlace(root.id, under: root.id))
        #expect(!graph.canPlace(root.id, under: child.id))
        #expect(graph.canPlace(child.id, under: nil))
    }

    @Test("A group with a subtree cannot be placed past the nesting cap")
    func enforcesDepthCap() {
        let a = FixtureGroup(name: "A")
        let b = FixtureGroup(name: "B", parentId: a.id)
        let other = FixtureGroup(name: "Other")
        let otherChild = FixtureGroup(name: "OtherChild", parentId: other.id)
        let graph = LibraryGroupGraph(groups: [a, b, other, otherChild])
        #expect(graph.canPlace(a.id, under: other.id))
        #expect(!graph.canPlace(a.id, under: otherChild.id))
        #expect(graph.canPlace(UUID(), under: b.id))
        #expect(graph.canCreateSubgroup(under: b.id))
    }

    @Test("Creating a subgroup is refused at the cap")
    func subgroupAtCap() {
        let one = FixtureGroup(name: "1")
        let two = FixtureGroup(name: "2", parentId: one.id)
        let three = FixtureGroup(name: "3", parentId: two.id)
        let graph = LibraryGroupGraph(groups: [one, two, three])
        #expect(!graph.canCreateSubgroup(under: three.id))
    }

    @Test("Descendants include every nested group")
    func descendants() {
        let root = FixtureGroup(name: "Root")
        let child = FixtureGroup(name: "Child", parentId: root.id)
        let grandchild = FixtureGroup(name: "Grandchild", parentId: child.id)
        let unrelated = FixtureGroup(name: "Unrelated")
        let graph = LibraryGroupGraph(groups: [root, child, grandchild, unrelated])
        #expect(graph.descendantIds(of: root.id) == [child.id, grandchild.id])
    }

    @Test("Path names run from the root to the group")
    func pathNames() {
        let root = FixtureGroup(name: "Clients")
        let child = FixtureGroup(name: "Acme", parentId: root.id)
        let graph = LibraryGroupGraph(groups: [child, root])
        #expect(graph.pathNames(to: child.id) == ["Clients", "Acme"])
    }

    @Test("Flattened groups are depth-first in manual order")
    func flattened() {
        let second = FixtureGroup(name: "B", sortOrder: 1)
        let first = FixtureGroup(name: "A", sortOrder: 0)
        let nested = FixtureGroup(name: "A1", parentId: first.id)
        let graph = LibraryGroupGraph(groups: [second, nested, first])
        #expect(graph.flattened() == [
            LibraryGroupGraph.FlatEntry(id: first.id, depth: 0),
            LibraryGroupGraph.FlatEntry(id: nested.id, depth: 1),
            LibraryGroupGraph.FlatEntry(id: second.id, depth: 0)
        ])
    }

    @Test("A cyclic pair is rooted")
    func cycleRooted() {
        var first = FixtureGroup(name: "First")
        var second = FixtureGroup(name: "Second")
        first.parentId = second.id
        second.parentId = first.id
        let graph = LibraryGroupGraph(groups: [first, second])
        #expect(graph.parentId(of: first.id) == nil)
        #expect(graph.parentId(of: second.id) == nil)
    }
}
