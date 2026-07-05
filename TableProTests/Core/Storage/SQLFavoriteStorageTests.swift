//
//  SQLFavoriteStorageTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SQLFavoriteStorage")
struct SQLFavoriteStorageTests {
    private let storage: SQLFavoriteStorage

    init() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("sql_favorites_\(UUID().uuidString).db")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.storage = SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true)
    }

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
        #expect(found?.folderId == parent.id)
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

    @Test("Keyword map without connection returns only global keywords")
    func fetchKeywordMapGlobalOnly() async {
        let scoped = makeFavorite(name: "Scoped", query: "SELECT 1", keyword: "scoped", connectionId: UUID())
        let global = makeFavorite(name: "Global", query: "SELECT 2", keyword: "global")

        _ = await storage.addFavorite(scoped)
        _ = await storage.addFavorite(global)

        let map = await storage.fetchKeywordMap()
        #expect(map["global"] != nil)
        #expect(map["scoped"] == nil)
    }

    // MARK: - Connection Lifecycle

    @Test("Connection cascade removes scoped favorites, keeps global and others")
    func deleteFavoritesByConnection() async {
        let connectionId = UUID()
        let otherConnectionId = UUID()
        let scoped = makeFavorite(name: "Scoped", keyword: "sc", connectionId: connectionId)
        let other = makeFavorite(name: "Other", connectionId: otherConnectionId)
        let global = makeFavorite(name: "Global")

        _ = await storage.addFavorite(scoped)
        _ = await storage.addFavorite(other)
        _ = await storage.addFavorite(global)

        _ = await storage.deleteFavoritesAndFolders(connectionId: connectionId)

        let remaining = await storage.fetchFavorites()
        #expect(!remaining.contains { $0.id == scoped.id })
        #expect(remaining.contains { $0.id == other.id })
        #expect(remaining.contains { $0.id == global.id })
    }

    @Test("Connection cascade removes scoped folders and detaches global favorites inside them")
    func deleteFoldersByConnection() async {
        let connectionId = UUID()
        let scopedFolder = makeFolder(name: "Scoped Folder", connectionId: connectionId)
        let otherFolder = makeFolder(name: "Other Folder", connectionId: UUID())
        _ = await storage.addFolder(scopedFolder)
        _ = await storage.addFolder(otherFolder)

        let globalInScopedFolder = makeFavorite(name: "Global In Folder", folderId: scopedFolder.id)
        _ = await storage.addFavorite(globalInScopedFolder)

        _ = await storage.deleteFavoritesAndFolders(connectionId: connectionId)

        let folders = await storage.fetchFolders()
        #expect(!folders.contains { $0.id == scopedFolder.id })
        #expect(folders.contains { $0.id == otherFolder.id })

        let survivor = await storage.fetchFavorite(id: globalInScopedFolder.id)
        #expect(survivor != nil, "A global favorite survives its connection-scoped folder")
        #expect(survivor?.folderId == nil, "Its dangling folder reference is cleared")
    }

    @Test("Orphan prune removes favorites and folders of dead connections only")
    func pruneOrphanedFavorites() async {
        let liveConnectionId = UUID()
        let deadConnectionId = UUID()
        let live = makeFavorite(name: "Live", keyword: "live", connectionId: liveConnectionId)
        let dead = makeFavorite(name: "Dead", keyword: "dead", connectionId: deadConnectionId)
        let global = makeFavorite(name: "Global", keyword: "glob")
        let deadFolder = makeFolder(name: "Dead Folder", connectionId: deadConnectionId)
        let liveFolder = makeFolder(name: "Live Folder", connectionId: liveConnectionId)

        _ = await storage.addFavorite(live)
        _ = await storage.addFavorite(dead)
        _ = await storage.addFavorite(global)
        _ = await storage.addFolder(deadFolder)
        _ = await storage.addFolder(liveFolder)

        let pruned = await storage.pruneOrphaned(retaining: [liveConnectionId])
        #expect(pruned == 1)

        let remaining = await storage.fetchFavorites()
        #expect(remaining.contains { $0.id == live.id })
        #expect(!remaining.contains { $0.id == dead.id })
        #expect(remaining.contains { $0.id == global.id })

        let folders = await storage.fetchFolders()
        #expect(!folders.contains { $0.id == deadFolder.id })
        #expect(folders.contains { $0.id == liveFolder.id })
    }

    @Test("Orphan prune is skipped when no active connections are known")
    func pruneSkippedWithoutActiveConnections() async {
        let scoped = makeFavorite(name: "Scoped", connectionId: UUID())
        _ = await storage.addFavorite(scoped)

        let pruned = await storage.pruneOrphaned(retaining: [])
        #expect(pruned == 0)

        let remaining = await storage.fetchFavorites()
        #expect(remaining.contains { $0.id == scoped.id })
    }

    @Test("hasFavorites reflects scoped favorites only")
    func hasFavoritesByConnection() async {
        let connectionId = UUID()
        let emptyConnectionId = UUID()
        _ = await storage.addFavorite(makeFavorite(name: "Scoped", connectionId: connectionId))
        _ = await storage.addFavorite(makeFavorite(name: "Global"))

        let scopedResult = await storage.hasFavorites(connectionIds: [connectionId])
        let emptyResult = await storage.hasFavorites(connectionIds: [emptyConnectionId])
        let noneResult = await storage.hasFavorites(connectionIds: [])
        #expect(scopedResult)
        #expect(!emptyResult)
        #expect(!noneResult)
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
