import Foundation
import Testing

@testable import TableProImport

@Suite("Path tree resolver")
struct PathTreeResolverTests {
    private func group(_ name: String, color: String? = nil) -> PathComponent {
        PathComponent(name: name, scope: nil, color: color)
    }

    private func resolve(_ paths: [[PathComponent]], existing: [PathNode] = []) -> (created: [PathNode], leaves: [UUID?]) {
        var ids = SequentialIds()
        return PathTreeResolver.resolve(paths, existing: existing) { ids.next() }
    }

    @Test("Two paths ending in the same name under different parents stay distinct")
    func sameLeafNameUnderDifferentParents() {
        let clientA = PathNode(id: UUID(), name: "Client A", parentId: nil, scope: nil)
        let clientB = PathNode(id: UUID(), name: "Client B", parentId: nil, scope: nil)
        let prodA = PathNode(id: UUID(), name: "Prod", parentId: clientA.id, scope: nil)

        let result = resolve(
            [[group("Client A"), group("Prod")], [group("Client B"), group("Prod")]],
            existing: [clientA, clientB, prodA]
        )

        #expect(result.leaves[0] == prodA.id)
        #expect(result.leaves[1] != prodA.id)
        #expect(result.created == [
            PathNode(id: ImportFixtures.uuid(1), name: "Prod", parentId: clientB.id, scope: nil)
        ])
    }

    @Test("An existing path is reused by trimmed, case-insensitive names")
    func existingPathIsReused() {
        let root = PathNode(id: UUID(), name: "Client A", parentId: nil, scope: nil)
        let leaf = PathNode(id: UUID(), name: "Prod", parentId: root.id, scope: nil)

        let result = resolve([[group(" client a "), group("PROD")]], existing: [root, leaf])

        #expect(result.created.isEmpty)
        #expect(result.leaves == [leaf.id])
    }

    @Test("Missing components are created parents first, with the color of the path")
    func missingComponentsAreCreated() {
        let root = PathNode(id: UUID(), name: "Client A", parentId: nil, scope: nil)

        let result = resolve([[group("Client A", color: "Red"), group("EU", color: "Blue"), group("Primary")]], existing: [root])

        #expect(result.created == [
            PathNode(id: ImportFixtures.uuid(1), name: "EU", parentId: root.id, scope: nil, color: "Blue"),
            PathNode(id: ImportFixtures.uuid(2), name: "Primary", parentId: ImportFixtures.uuid(1), scope: nil)
        ])
        #expect(result.leaves == [ImportFixtures.uuid(2)])
    }

    @Test("A path repeated in one call is created once")
    func repeatedPathIsCreatedOnce() {
        let result = resolve([[group("Prod")], [group(" prod ")], []])

        #expect(result.created.map(\.name) == ["Prod"])
        #expect(result.leaves == [ImportFixtures.uuid(1), ImportFixtures.uuid(1), nil])
    }

    @Test("Folders match only within the same scope")
    func foldersMatchByScope() {
        let connection = UUID()
        let other = UUID()
        let scoped = PathNode(id: UUID(), name: "Reports", parentId: nil, scope: connection)

        let result = resolve(
            [
                [PathComponent(name: "Reports", scope: connection, color: nil)],
                [PathComponent(name: "Reports", scope: nil, color: nil)],
                [PathComponent(name: "Reports", scope: other, color: nil)]
            ],
            existing: [scoped]
        )

        #expect(result.leaves == [scoped.id, ImportFixtures.uuid(1), ImportFixtures.uuid(2)])
        #expect(result.created.map(\.scope) == [nil, other])
    }

    @Test("Empty component names are skipped")
    func emptyComponentsAreSkipped() {
        let result = resolve([[group("  "), group("Prod")]])

        #expect(result.created == [PathNode(id: ImportFixtures.uuid(1), name: "Prod", parentId: nil, scope: nil)])
    }
}
