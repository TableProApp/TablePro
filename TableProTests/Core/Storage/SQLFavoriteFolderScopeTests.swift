//
//  SQLFavoriteFolderScopeTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Issue #3045. A folder now carries a scope the user can set, and setting it writes that folder
/// and nothing else: `FavoritesTreeBuilder` places every relative whose container a connection
/// cannot resolve, so a walk would only reach records the user never selected.
@Suite("SQL favorite folder scope")
struct SQLFavoriteFolderScopeTests {
    private let storage: SQLFavoriteStorage

    init() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("sql_favorites_folder_scope_\(UUID().uuidString).db")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.storage = SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true)
    }

    @discardableResult
    private func store(_ folder: SQLFavoriteFolder) async -> SQLFavoriteFolder {
        #expect(await storage.addFolder(folder))
        return folder
    }

    // MARK: - One row, and only that row

    @Test("Making a folder global leaves the folders above it alone")
    func wideningLeavesAncestorsAlone() async {
        let connectionId = UUID()
        let top = await store(SQLFavoriteFolder(name: "Acme", connectionId: connectionId))
        let leaf = await store(SQLFavoriteFolder(name: "Weekly", parentId: top.id, connectionId: connectionId))

        #expect(await storage.setFolderScope(id: leaf.id, connectionId: nil).succeeded)

        #expect(await storage.fetchFolder(id: leaf.id)?.connectionId == nil)
        #expect(await storage.fetchFolder(id: top.id)?.connectionId == connectionId)
    }

    @Test("Making a folder global leaves the folders inside it alone")
    func wideningLeavesDescendantsAlone() async {
        let connectionId = UUID()
        let top = await store(SQLFavoriteFolder(name: "Reports", connectionId: connectionId))
        let child = await store(SQLFavoriteFolder(name: "Weekly", parentId: top.id, connectionId: connectionId))

        #expect(await storage.setFolderScope(id: top.id, connectionId: nil).succeeded)

        #expect(await storage.fetchFolder(id: child.id)?.connectionId == connectionId)
    }

    @Test("Confining a folder leaves the folders above it alone")
    func narrowingLeavesAncestorsAlone() async {
        let connectionId = UUID()
        let top = await store(SQLFavoriteFolder(name: "Reports", connectionId: nil))
        let child = await store(SQLFavoriteFolder(name: "Weekly", parentId: top.id, connectionId: nil))

        #expect(await storage.setFolderScope(id: child.id, connectionId: connectionId).succeeded)

        #expect(await storage.fetchFolder(id: top.id)?.connectionId == nil)
    }

    @Test("Confining a folder leaves the folders inside it alone")
    func narrowingLeavesDescendantsAlone() async {
        let connectionId = UUID()
        let top = await store(SQLFavoriteFolder(name: "Reports", connectionId: nil))
        let child = await store(SQLFavoriteFolder(name: "Weekly", parentId: top.id, connectionId: nil))
        let grandchild = await store(SQLFavoriteFolder(name: "Counts", parentId: child.id, connectionId: nil))

        #expect(await storage.setFolderScope(id: top.id, connectionId: connectionId).succeeded)

        #expect(await storage.fetchFolder(id: child.id)?.connectionId == nil)
        #expect(await storage.fetchFolder(id: grandchild.id)?.connectionId == nil)
    }

    /// A connection may keep its own folder inside a global one, and that folder is invisible to
    /// everybody else. A walk down the subtree meant confining the global parent from one
    /// connection quietly moved another connection's whole branch into it.
    @Test("Confining a global folder leaves a subfolder belonging to another connection alone")
    func narrowingLeavesAnotherConnectionsFolderAlone() async {
        let mine = UUID()
        let theirs = UUID()
        let shared = await store(SQLFavoriteFolder(name: "Shared", connectionId: nil))
        let foreign = await store(SQLFavoriteFolder(name: "Theirs", parentId: shared.id, connectionId: theirs))

        #expect(await storage.setFolderScope(id: shared.id, connectionId: mine).succeeded)

        #expect(await storage.fetchFolder(id: foreign.id)?.connectionId == theirs)
    }

    /// The unique index on (keyword, connection_id) is one reason a folder scope change never
    /// rewrites a query's own scope: a query pulled into a connection that already holds its
    /// keyword would fail the write. The other is that the user asked about a folder.
    @Test("A folder scope change never rewrites the scope of a query inside it")
    func aScopeChangeLeavesQueriesAlone() async {
        let connectionId = UUID()
        let folder = await store(SQLFavoriteFolder(name: "Reports", connectionId: nil))
        let query = SQLFavorite(name: "Counts", query: "SELECT 1", keyword: "cnt", folderId: folder.id)
        #expect(await storage.addFavorite(query))

        #expect(await storage.setFolderScope(id: folder.id, connectionId: connectionId).succeeded)

        #expect(await storage.fetchFavorite(id: query.id)?.connectionId == nil)
        #expect(await storage.fetchFavorite(id: query.id)?.folderId == folder.id)
    }

    // MARK: - Reporting

    /// The scope it was in, not the one it is going to, because a record that changed scope has
    /// left a list it used to be in and the subscriber holding that list has to be told.
    @Test("A scope change reports the scope the folder was in")
    func aScopeChangeReportsThePreviousScope() async {
        let connectionId = UUID()
        let folder = await store(SQLFavoriteFolder(name: "Reports", connectionId: connectionId))

        let result = await storage.setFolderScope(id: folder.id, connectionId: nil)

        #expect(result == .updatedExisting(previousConnectionId: connectionId))
    }

    @Test("Setting the scope of a folder that is no longer stored fails rather than reporting success")
    func aMissingFolderFails() async {
        #expect(await storage.setFolderScope(id: UUID(), connectionId: nil) == .failed)
    }

    // MARK: - Writes that must not carry a scope with them

    /// The sidebar holds a copy of every folder it drew. Renaming by writing that copy back put its
    /// `connection_id` back too, over a scope another window had just set.
    @Test("Renaming a folder leaves the scope another window set")
    func renamingDoesNotRevertAScope() async {
        let connectionId = UUID()
        let stale = await store(SQLFavoriteFolder(name: "Reports", connectionId: connectionId))
        _ = await storage.setFolderScope(id: stale.id, connectionId: nil)

        #expect(await storage.renameFolder(id: stale.id, name: "Weekly reports").succeeded)

        let stored = await storage.fetchFolder(id: stale.id)
        #expect(stored?.name == "Weekly reports")
        #expect(stored?.connectionId == nil)
    }

    @Test("Renaming a folder reports the scope it is in")
    func renamingReportsTheScope() async {
        let connectionId = UUID()
        let folder = await store(SQLFavoriteFolder(name: "Reports", connectionId: connectionId))

        let write = await storage.renameFolder(id: folder.id, name: "Weekly")

        #expect(write == .updatedExisting(previousConnectionId: connectionId))
    }

    @Test("Renaming a folder that is no longer stored fails rather than reporting success")
    func renamingAMissingFolderFails() async {
        #expect(await storage.renameFolder(id: UUID(), name: "Gone") == .failed)
    }

    @Test("Moving a query between folders leaves its scope alone")
    func movingAQueryDoesNotRescopeIt() async {
        let folder = await store(SQLFavoriteFolder(name: "Reports", connectionId: nil))
        let query = SQLFavorite(name: "Counts", query: "SELECT 1", connectionId: nil)
        #expect(await storage.addFavorite(query))

        let write = await storage.setFavoriteFolder(id: query.id, folderId: folder.id)

        #expect(write == .updatedExisting(previousConnectionId: nil))
        let stored = await storage.fetchFavorite(id: query.id)
        #expect(stored?.folderId == folder.id)
        #expect(stored?.connectionId == nil)
    }

    @Test("Moving a query to the root clears its folder")
    func movingAQueryToTheRootClearsItsFolder() async {
        let folder = await store(SQLFavoriteFolder(name: "Reports", connectionId: nil))
        let query = SQLFavorite(name: "Counts", query: "SELECT 1", folderId: folder.id)
        #expect(await storage.addFavorite(query))

        #expect(await storage.setFavoriteFolder(id: query.id, folderId: nil).succeeded)

        #expect(await storage.fetchFavorite(id: query.id)?.folderId == nil)
    }

    @Test("Moving a query that is no longer stored fails rather than reporting success")
    func movingAMissingQueryFails() async {
        #expect(await storage.setFavoriteFolder(id: UUID(), folderId: nil) == .failed)
    }

    // MARK: - Reading a folder across scopes

    /// The edit dialog has to be able to name the folder a query is in even when that folder
    /// belongs to another connection, or its Picker shows no selection and saves that over a
    /// placement the owning connection still draws.
    @Test("A folder can be read by id whatever connection owns it")
    func aFolderIsReadableAcrossScopes() async {
        let folder = await store(SQLFavoriteFolder(name: "Reports", connectionId: UUID()))

        #expect(await storage.fetchFolder(id: folder.id)?.name == "Reports")
    }

    @Test("Reading a folder that is not stored returns nothing")
    func readingAMissingFolderReturnsNothing() async {
        #expect(await storage.fetchFolder(id: UUID()) == nil)
    }
}
