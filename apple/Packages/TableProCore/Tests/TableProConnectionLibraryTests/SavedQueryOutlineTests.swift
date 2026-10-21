import Foundation
@testable import TableProConnectionLibrary
import Testing

private struct OutlineQuery: SavedQueryRepresentable, Hashable {
    var id = UUID()
    var name: String
    var query = "SELECT 1"
    var keyword: String?
    var folderId: UUID?
    var connectionId: UUID?
    var sortOrder = 0
    var createdAt = Date(timeIntervalSince1970: 1_000)
}

private struct OutlineFolder: SavedQueryFolderRepresentable, Hashable {
    var id = UUID()
    var name: String
    var parentId: UUID?
    var connectionId: UUID?
    var sortOrder = 0
}

private typealias Node = SavedQueryOutlineNode<OutlineFolder, OutlineQuery>

private indirect enum Shape: Equatable {
    case folder(String, [Shape])
    case query(String)
}

private func shape(_ nodes: [Node]) -> [Shape] {
    nodes.map { node in
        switch node {
        case .folder(let folder, let children):
            return .folder(folder.name, shape(children))
        case .query(let query):
            return .query(query.name)
        }
    }
}

struct SavedQueryOutlineTests {
    private let connectionId = UUID()

    @Test("Folders come before queries, each ordered by sort order, then name, then id")
    func order() {
        let beta = OutlineFolder(name: "Beta")
        let alpha = OutlineFolder(name: "alpha")
        let pinned = OutlineFolder(name: "Zulu", sortOrder: -1)
        let queries = [
            OutlineQuery(name: "Query 10"),
            OutlineQuery(name: "Query 9"),
            OutlineQuery(name: "Last", sortOrder: 1)
        ]

        let nodes = SavedQueryOutline.build(folders: [beta, alpha, pinned], queries: queries)

        #expect(shape(nodes) == [
            .folder("Zulu", []), .folder("alpha", []), .folder("Beta", []),
            .query("Query 9"), .query("Query 10"), .query("Last")
        ])
    }

    @Test("A query sits in its folder, and a folder under its parent")
    func nesting() {
        let reports = OutlineFolder(name: "Reports")
        let daily = OutlineFolder(name: "Daily", parentId: reports.id)
        let query = OutlineQuery(name: "Users", folderId: daily.id)

        let nodes = SavedQueryOutline.build(folders: [daily, reports], queries: [query])

        #expect(shape(nodes) == [.folder("Reports", [.folder("Daily", [.query("Users")])])])
    }

    @Test("A query whose folder is not here, and a folder whose parent is not here, sit at the root")
    func missingParentGoesToRoot() {
        let orphan = OutlineFolder(name: "Orphan", parentId: UUID())
        let query = OutlineQuery(name: "Lost", folderId: UUID())

        let nodes = SavedQueryOutline.build(folders: [orphan], queries: [query])

        #expect(shape(nodes) == [.folder("Orphan", []), .query("Lost")])
    }

    @Test("Every folder on a parent cycle sits at the root and keeps its queries")
    func cycleGoesToRoot() {
        var first = OutlineFolder(name: "First")
        let second = OutlineFolder(name: "Second", parentId: first.id)
        first.parentId = second.id
        let query = OutlineQuery(name: "Inside", folderId: second.id)

        let nodes = SavedQueryOutline.build(folders: [first, second], queries: [query])

        #expect(shape(nodes) == [.folder("First", []), .folder("Second", [.query("Inside")])])
    }

    @Test("Folders nest past the connection library's depth cap")
    func depthIsUnlimited() {
        let one = OutlineFolder(name: "1")
        let two = OutlineFolder(name: "2", parentId: one.id)
        let three = OutlineFolder(name: "3", parentId: two.id)
        let four = OutlineFolder(name: "4", parentId: three.id)
        let five = OutlineFolder(name: "5", parentId: four.id)
        let query = OutlineQuery(name: "Deep", folderId: five.id)

        let nodes = SavedQueryOutline.build(folders: [five, four, three, two, one], queries: [query])

        #expect(shape(nodes) == [
            .folder("1", [.folder("2", [.folder("3", [.folder("4", [.folder("5", [.query("Deep")])])])])])
        ])
        #expect(SavedQueryOutline.folderRows([five, four, three, two, one]).map(\.depth) == [0, 1, 2, 3, 4])
    }

    @Test("A connection sees its own records and the global ones")
    func visibility() {
        let own = OutlineQuery(name: "Own", connectionId: connectionId)
        let global = OutlineQuery(name: "Global")
        let other = OutlineQuery(name: "Other", connectionId: UUID())
        let ownFolder = OutlineFolder(name: "Own", connectionId: connectionId)
        let globalFolder = OutlineFolder(name: "Global")
        let otherFolder = OutlineFolder(name: "Other", connectionId: UUID())

        #expect(SavedQueryOutline.visible([own, global, other], to: connectionId).map(\.name) == ["Own", "Global"])
        #expect(SavedQueryOutline.visible([ownFolder, globalFolder, otherFolder], to: connectionId).map(\.name) == ["Own", "Global"])
        #expect(SavedQueryOutline.isVisible(scope: nil, to: connectionId))
        #expect(!SavedQueryOutline.isVisible(scope: UUID(), to: connectionId))
    }

    @Test("A global query filed in another connection's folder shows at the root")
    func globalQueryInHiddenFolderShowsAtRoot() {
        let hidden = OutlineFolder(name: "Theirs", connectionId: UUID())
        let query = OutlineQuery(name: "Shared", folderId: hidden.id)
        let folders = SavedQueryOutline.visible([hidden], to: connectionId)
        let queries = SavedQueryOutline.visible([query], to: connectionId)

        let nodes = SavedQueryOutline.build(folders: folders, queries: queries)

        #expect(shape(nodes) == [.query("Shared")])
    }

    @Test("Folder rows list every folder in outline order with its depth")
    func folderRows() {
        let reports = OutlineFolder(name: "Reports")
        let daily = OutlineFolder(name: "Daily", parentId: reports.id)
        let archive = OutlineFolder(name: "Archive")

        let rows = SavedQueryOutline.folderRows([daily, reports, archive])

        #expect(rows.map(\.folder.name) == ["Archive", "Reports", "Daily"])
        #expect(rows.map(\.depth) == [0, 0, 1])
        #expect(rows.map(\.id) == [archive.id, reports.id, daily.id])
    }

    @Test("Search matches a query's name, keyword or SQL, ignoring case")
    func searchMatchesNameKeywordAndSQL() {
        let queries = [
            OutlineQuery(name: "Daily users"),
            OutlineQuery(name: "Revenue", keyword: "rev"),
            OutlineQuery(name: "Orders", query: "SELECT * FROM orders WHERE status = 'open'"),
            OutlineQuery(name: "Unrelated")
        ]
        let nodes = SavedQueryOutline.build(folders: [OutlineFolder](), queries: queries)

        #expect(shape(SavedQueryOutline.filter(nodes, matching: "USERS")) == [.query("Daily users")])
        #expect(shape(SavedQueryOutline.filter(nodes, matching: "REV")) == [.query("Revenue")])
        #expect(shape(SavedQueryOutline.filter(nodes, matching: "status")) == [.query("Orders")])
    }

    @Test("Search keeps a folder holding a match, and a matching folder with only its matching children")
    func searchKeepsFolders() {
        let reports = OutlineFolder(name: "Reports")
        let daily = OutlineFolder(name: "Daily", parentId: reports.id)
        let empty = OutlineFolder(name: "Empty")
        let queries = [
            OutlineQuery(name: "Active users", folderId: daily.id),
            OutlineQuery(name: "Revenue", folderId: daily.id),
            OutlineQuery(name: "Monthly", folderId: reports.id)
        ]
        let nodes = SavedQueryOutline.build(folders: [reports, daily, empty], queries: queries)

        #expect(shape(SavedQueryOutline.filter(nodes, matching: "active")) == [
            .folder("Reports", [.folder("Daily", [.query("Active users")])])
        ])
        #expect(shape(SavedQueryOutline.filter(nodes, matching: "reports")) == [.folder("Reports", [])])
        let unmatched = SavedQueryOutline.filter(nodes, matching: "nothing")
        #expect(unmatched.isEmpty)
    }

    @Test("A blank search shows everything")
    func blankSearchKeepsEverything() {
        let folder = OutlineFolder(name: "Reports")
        let nodes = SavedQueryOutline.build(folders: [folder], queries: [OutlineQuery(name: "Daily", folderId: folder.id)])

        #expect(SavedQueryOutline.filter(nodes, matching: "  ") == nodes)
    }

    @Test("A node's id tells a folder from a query with the same UUID")
    func nodeIdentity() {
        let id = UUID()
        let folder = Node.folder(OutlineFolder(id: id, name: "Reports"), children: [])
        let query = Node.query(OutlineQuery(id: id, name: "Daily"))

        #expect(folder.id == .folder(id))
        #expect(query.id == .query(id))
        #expect(folder.id != query.id)
        #expect(folder.children?.isEmpty == true)
        #expect(query.children == nil)
    }
}
