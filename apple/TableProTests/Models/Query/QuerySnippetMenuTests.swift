//
//  QuerySnippetMenuTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct QuerySnippetMenuTests {
    private static let connectionId = UUID()

    @Test("A connection's saved queries are listed in their folders, with Save as Favorite last")
    func listsSavedQueriesInFolders() {
        let reports = SQLFavoriteFolder(name: "Reports", sortOrder: 0)
        let orders = SQLFavoriteFolder(name: "Orders", connectionId: Self.connectionId, sortOrder: 1)
        let topCustomers = SQLFavorite(name: "Top customers", query: "SELECT 1", folderId: reports.id)
        let recentOrders = SQLFavorite(
            name: "Recent orders",
            query: "SELECT 2",
            folderId: orders.id,
            connectionId: Self.connectionId
        )
        let count = SQLFavorite(name: "Count", query: "SELECT count(*) FROM ${1:orders}")

        let entries = QuerySnippetMenu.entries(folders: [orders, reports], favorites: [count, recentOrders, topCustomers])

        #expect(entries == [
            .folder(reports, children: [.savedQuery(topCustomers)]),
            .folder(orders, children: [.savedQuery(recentOrders)]),
            .savedQuery(count),
            .divider,
            .saveCurrentQuery,
        ])
    }

    @Test("Folders nest, and one with no saved query under it is left out")
    func nestsAndPrunesFolders() {
        let parent = SQLFavoriteFolder(name: "Ops", sortOrder: 0)
        let child = SQLFavoriteFolder(name: "Locks", parentId: parent.id, sortOrder: 0)
        let empty = SQLFavoriteFolder(name: "Drafts", sortOrder: 1)
        let emptyChild = SQLFavoriteFolder(name: "Old", parentId: empty.id)
        let locks = SQLFavorite(name: "Locks held", query: "SELECT * FROM pg_locks", folderId: child.id)

        let entries = QuerySnippetMenu.entries(folders: [parent, child, empty, emptyChild], favorites: [locks])

        #expect(entries == [
            .folder(parent, children: [.folder(child, children: [.savedQuery(locks)])]),
            .divider,
            .saveCurrentQuery,
        ])
    }

    @Test("A saved query whose folder this connection cannot see is listed at the top level")
    func unresolvedFolderGoesToTheRoot() {
        let stray = SQLFavorite(name: "Stray", query: "SELECT 1", folderId: UUID())

        #expect(QuerySnippetMenu.entries(folders: [], favorites: [stray]) == [.savedQuery(stray), .divider, .saveCurrentQuery])
    }

    @Test("With no saved query the menu says so and still offers to save the current one")
    func emptyState() {
        let lonelyFolder = SQLFavoriteFolder(name: "Empty")

        #expect(QuerySnippetMenu.entries(folders: [], favorites: []) == [.empty, .divider, .saveCurrentQuery])
        #expect(QuerySnippetMenu.entries(folders: [lonelyFolder], favorites: []) == [.empty, .divider, .saveCurrentQuery])
    }
}
