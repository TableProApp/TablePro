//
//  FavoritesOutlineSelectionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Favorites outline selection")
@MainActor
struct FavoritesOutlineSelectionTests {
    private func table(_ name: String, schema: String? = "public") -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: nil, schema: schema)
    }

    private func favorite(_ name: String) -> SQLFavorite {
        SQLFavorite(name: name, query: "SELECT 1")
    }

    private func database(_ name: String) -> FavoriteDatabaseEntry {
        FavoriteDatabaseEntry(connectionId: UUID(), database: name, environment: .development)
    }

    @Test("Section titles refuse selection, objects accept it")
    func headersRefuseSelection() {
        #expect(FavoritesOutlineSelection.isSelectable(.header("Tables")) == false)
        #expect(FavoritesOutlineSelection.isSelectable(.database(database("app"))))
        #expect(FavoritesOutlineSelection.isSelectable(.databaseEnvironment(FavoriteDatabaseGroup(
            environment: .development,
            entries: [database("app")]
        ))))
        #expect(FavoritesOutlineSelection.isSelectable(.table(table("users"))))
        #expect(FavoritesOutlineSelection.isSelectable(.query(.favorite(favorite("daily")))))
        #expect(FavoritesOutlineSelection.isSelectable(.teamQuery(id: "t1", name: "Shared", publishedBy: nil)))
    }

    @Test("A table row maps to the table selection the app persists")
    func tableMapsToSelection() {
        let selection = FavoritesOutlineSelection.selection(for: .table(table("users")), database: "app")
        #expect(selection == .table(database: "app", schema: "public", name: "users"))
    }

    @Test("A saved query maps to its node id")
    func queryMapsToNodeId() {
        let node = FavoriteNode.favorite(favorite("daily"))
        #expect(FavoritesOutlineSelection.selection(for: .query(node), database: nil) == .node(id: node.id))
    }

    @Test("A database row maps to its stable node id")
    func databaseMapsToNodeId() {
        let entry = database("analytics")
        let selection = FavoritesOutlineSelection.selection(for: .database(entry), database: nil)

        #expect(selection == .node(id: FavoritesOutlineNode.databaseId(entry)))
    }

    @Test("Database environment expansion is independent per connection")
    @MainActor
    func databaseEnvironmentExpansionIsConnectionScoped() {
        let firstConnection = UUID()
        let secondConnection = UUID()
        defer {
            FavoritesExpansionState.shared.removeConnection(firstConnection)
            FavoritesExpansionState.shared.removeConnection(secondConnection)
        }

        #expect(FavoritesExpansion.isDatabaseEnvironmentExpanded(.testing, connectionId: firstConnection))
        #expect(FavoritesExpansion.isDatabaseEnvironmentExpanded(.testing, connectionId: secondConnection))

        FavoritesExpansion.setDatabaseEnvironmentExpanded(
            .testing,
            expanded: false,
            connectionId: firstConnection
        )

        #expect(!FavoritesExpansion.isDatabaseEnvironmentExpanded(.testing, connectionId: firstConnection))
        #expect(FavoritesExpansion.isDatabaseEnvironmentExpanded(.testing, connectionId: secondConnection))
    }

    /// Team Library rows carried no tag at all before, so the keyboard could never reach them.
    @Test("A Team Library row maps to a selection of its own")
    func teamQueryMapsToSelection() {
        let selection = FavoritesOutlineSelection.selection(
            for: .teamQuery(id: "abc", name: "Shared", publishedBy: "sam"), database: nil
        )
        #expect(selection == .node(id: FavoritesOutlineNode.teamQueryId("abc")))
    }

    @Test("A header maps to no selection")
    func headerMapsToNothing() {
        #expect(FavoritesOutlineSelection.selection(for: .header("Queries"), database: "app") == nil)
    }

    /// Restoring a persisted selection must find the same row again without a live TableInfo.
    @Test("A persisted selection round-trips to the row id")
    func selectionRoundTripsToNodeId() {
        let selection = FavoriteSelection.table(database: "app", schema: "public", name: "users")
        let expected = FavoritesOutlineNode.tableId(database: "app", schema: "public", name: "users")
        #expect(FavoritesOutlineSelection.nodeId(for: selection) == expected)
        #expect(FavoritesOutlineSelection.nodeId(for: .node(id: "fav-1")) == "fav-1")
    }

    @Test("Type-select uses the name a user would type, never a section title")
    func typeSelectSkipsHeaders() {
        #expect(FavoritesOutlineSelection.matchString(for: .header("Tables")) == nil)
        #expect(FavoritesOutlineSelection.matchString(for: .database(database("analytics"))) == "analytics")
        #expect(FavoritesOutlineSelection.matchString(for: .table(table("orders"))) == "orders")
        #expect(FavoritesOutlineSelection.matchString(for: .query(.favorite(favorite("daily")))) == "daily")
        #expect(
            FavoritesOutlineSelection.matchString(
                for: .teamQuery(id: "t", name: "Shared", publishedBy: nil)
            ) == "Shared"
        )
    }

    @Test("Only folders are expandable")
    func onlyFoldersExpand() {
        let leaf = FavoritesOutlineNode(id: "a", kind: .query(.favorite(favorite("daily"))))
        let branch = FavoritesOutlineNode(
            id: "b",
            kind: .query(.folder(SQLFavoriteFolder(name: "Reports"), children: []))
        )
        let header = FavoritesOutlineNode(id: "c", kind: .header("Queries"))
        let databaseGroup = FavoritesOutlineNode(
            id: "d",
            kind: .databaseEnvironment(FavoriteDatabaseGroup(
                environment: .development,
                entries: [database("app")]
            ))
        )
        #expect(leaf.isExpandable == false)
        #expect(branch.isExpandable)
        #expect(header.isExpandable == false)
        #expect(databaseGroup.isExpandable)
    }
}
