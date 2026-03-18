//
//  SQLFavoriteStorageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQLFavoriteStorage", .serialized)
struct SQLFavoriteStorageTests {
    private let storage = SQLFavoriteStorage(isolatedForTesting: true)

    // MARK: - Helpers

    private func makeFavorite(
        name: String = "Test Query",
        query: String = "SELECT 1",
        keyword: String? = nil,
        folderId: UUID? = nil,
        connectionId: UUID? = nil
    ) -> SQLFavorite {
        SQLFavorite(
            name: name,
            query: query,
            keyword: keyword,
            folderId: folderId,
            connectionId: connectionId
        )
    }

    private func makeFolder(
        name: String = "Test Folder",
        parentId: UUID? = nil,
        connectionId: UUID? = nil
    ) -> SQLFavoriteFolder {
        SQLFavoriteFolder(
            name: name,
            parentId: parentId,
            connectionId: connectionId
        )
    }

    // MARK: - Favorite CRUD

    @Test("Add and fetch favorite")
    func addAndFetch() async {
        let fav = makeFavorite(name: "My Query", query: "SELECT * FROM users")
        let added = await storage.addFavorite(fav)
        #expect(added)

        let fetched = await storage.fetchFavorites()
        #expect(fetched.contains { $0.id == fav.id })
        let found = fetched.first { $0.id == fav.id }
        #expect(found?.name == "My Query")
        #expect(found?.query == "SELECT * FROM users")
    }

    @Test("Update favorite")
    func updateFavorite() async {
        var fav = makeFavorite(name: "Original")
        _ = await storage.addFavorite(fav)

        fav.name = "Updated"
        fav.keyword = "upd"
        let updated = await storage.updateFavorite(fav)
        #expect(updated)

        let fetched = await storage.fetchFavorites()
        let found = fetched.first { $0.id == fav.id }
        #expect(found?.name == "Updated")
        #expect(found?.keyword == "upd")
    }

    @Test("Delete favorite")
    func deleteFavorite() async {
        let fav = makeFavorite()
        _ = await storage.addFavorite(fav)

        let deleted = await storage.deleteFavorite(id: fav.id)
        #expect(deleted)

        let fetched = await storage.fetchFavorites()
        #expect(!fetched.contains { $0.id == fav.id })
    }

    // MARK: - Favorites in Folders

    @Test("Favorite in folder is fetched when no folderId filter")
    func favoriteInFolderFetchedWithoutFilter() async {
        let folder = makeFolder(name: "Reports")
        _ = await storage.addFolder(folder)

        let fav = makeFavorite(name: "In Folder", folderId: folder.id)
        _ = await storage.addFavorite(fav)

        let allFavorites = await storage.fetchFavorites()
        #expect(allFavorites.contains { $0.id == fav.id })
        #expect(allFavorites.first { $0.id == fav.id }?.folderId == folder.id)
    }

    @Test("Fetch favorites filtered by folderId")
    func fetchByFolderId() async {
        let folder = makeFolder()
        _ = await storage.addFolder(folder)

        let inFolder = makeFavorite(name: "In Folder", folderId: folder.id)
        let atRoot = makeFavorite(name: "At Root")
        _ = await storage.addFavorite(inFolder)
        _ = await storage.addFavorite(atRoot)

        let folderFavs = await storage.fetchFavorites(folderId: folder.id)
        #expect(folderFavs.contains { $0.id == inFolder.id })
        #expect(!folderFavs.contains { $0.id == atRoot.id })
    }

    // MARK: - Connection Scoping

    @Test("Fetch favorites by connectionId includes global and scoped")
    func fetchByConnectionId() async {
        let connId = UUID()
        let global = makeFavorite(name: "Global", connectionId: nil)
        let scoped = makeFavorite(name: "Scoped", connectionId: connId)
        let other = makeFavorite(name: "Other Connection", connectionId: UUID())

        _ = await storage.addFavorite(global)
        _ = await storage.addFavorite(scoped)
        _ = await storage.addFavorite(other)

        let fetched = await storage.fetchFavorites(connectionId: connId)
        #expect(fetched.contains { $0.id == global.id })
        #expect(fetched.contains { $0.id == scoped.id })
        #expect(!fetched.contains { $0.id == other.id })
    }

    // MARK: - Folder CRUD

    @Test("Add and fetch folder")
    func addAndFetchFolder() async {
        let folder = makeFolder(name: "Reports")
        let added = await storage.addFolder(folder)
        #expect(added)

        let fetched = await storage.fetchFolders()
        #expect(fetched.contains { $0.id == folder.id })
    }

    @Test("Delete folder moves children to parent")
    func deleteFolderMovesChildren() async {
        let parent = makeFolder(name: "Parent")
        _ = await storage.addFolder(parent)

        let child = makeFolder(name: "Child", parentId: parent.id)
        _ = await storage.addFolder(child)

        let fav = makeFavorite(name: "In Child", folderId: child.id)
        _ = await storage.addFavorite(fav)

        _ = await storage.deleteFolder(id: child.id)

        // Favorite should now be in parent folder
        let fetched = await storage.fetchFavorites()
        let found = fetched.first { $0.id == fav.id }
        #expect(found?.folderId == parent.id.uuidString || found?.folderId == parent.id)
    }

    // MARK: - Keyword

    @Test("Keyword uniqueness check")
    func keywordUniqueness() async {
        let fav = makeFavorite(keyword: "sel")
        _ = await storage.addFavorite(fav)

        let available = await storage.isKeywordAvailable("sel", connectionId: nil)
        #expect(!available)

        let otherAvailable = await storage.isKeywordAvailable("other", connectionId: nil)
        #expect(otherAvailable)
    }

    @Test("Keyword uniqueness excludes self")
    func keywordUniquenessExcludesSelf() async {
        let fav = makeFavorite(keyword: "sel")
        _ = await storage.addFavorite(fav)

        let available = await storage.isKeywordAvailable("sel", connectionId: nil, excludingFavoriteId: fav.id)
        #expect(available)
    }

    @Test("Fetch keyword map")
    func fetchKeywordMap() async {
        let fav1 = makeFavorite(name: "Q1", query: "SELECT 1", keyword: "q1")
        let fav2 = makeFavorite(name: "Q2", query: "SELECT 2", keyword: "q2")
        let noKeyword = makeFavorite(name: "No Keyword", query: "SELECT 3")

        _ = await storage.addFavorite(fav1)
        _ = await storage.addFavorite(fav2)
        _ = await storage.addFavorite(noKeyword)

        let map = await storage.fetchKeywordMap()
        #expect(map["q1"]?.name == "Q1")
        #expect(map["q2"]?.query == "SELECT 2")
        #expect(map.count >= 2)
    }

    // MARK: - FTS5 Search

    @Test("Search finds favorites by query text")
    func searchByQueryText() async {
        let fav = makeFavorite(name: "User Report", query: "SELECT * FROM large_table WHERE active = true")
        _ = await storage.addFavorite(fav)

        let results = await storage.fetchFavorites(searchText: "large_table")
        #expect(results.contains { $0.id == fav.id })
    }
}
