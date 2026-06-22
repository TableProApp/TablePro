import Foundation
@testable import TablePro
import Testing

@Suite("TagFilter")
struct TagFilterTests {
    private func connection(tagIds: [UUID]) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Conn")
        connection.tagIds = tagIds
        return connection
    }

    @Test("Inactive filter matches everything")
    func inactiveMatchesAll() {
        let filter = TagFilter()
        #expect(filter.matches(connection(tagIds: [])))
        #expect(filter.matches(connection(tagIds: [UUID()])))
    }

    @Test("Match any matches when at least one tag overlaps")
    func matchAny() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let filter = TagFilter(selectedIds: [a, b], mode: .any)
        #expect(filter.matches(connection(tagIds: [b, c])))
        #expect(!filter.matches(connection(tagIds: [c])))
    }

    @Test("Match all requires every selected tag")
    func matchAll() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let filter = TagFilter(selectedIds: [a, b], mode: .all)
        #expect(filter.matches(connection(tagIds: [a, b, c])))
        #expect(!filter.matches(connection(tagIds: [a])))
    }

    @Test("filterGroupTreeByTags keeps matching connections and prunes groups without matches")
    func treeFilter() {
        let a = UUID()
        let matching = connection(tagIds: [a])
        let other = connection(tagIds: [UUID()])
        let group = ConnectionGroup(name: "Prod")
        let tree: [ConnectionGroupTreeNode] = [
            .group(group, children: [.connection(matching), .connection(other)]),
            .connection(other),
        ]

        let filtered = filterGroupTreeByTags(tree, filter: TagFilter(selectedIds: [a], mode: .any))

        #expect(filtered.count == 1)
        guard case .group(_, let children) = filtered[0] else {
            Issue.record("Expected a group node")
            return
        }
        #expect(children.count == 1)
        guard case .connection(let conn) = children[0] else {
            Issue.record("Expected a connection node")
            return
        }
        #expect(conn.id == matching.id)
    }

    @Test("filterGroupTreeByTags returns input unchanged when filter inactive")
    func treeFilterInactive() {
        let tree: [ConnectionGroupTreeNode] = [.connection(connection(tagIds: []))]
        let filtered = filterGroupTreeByTags(tree, filter: TagFilter())
        #expect(filtered.count == 1)
    }
}
