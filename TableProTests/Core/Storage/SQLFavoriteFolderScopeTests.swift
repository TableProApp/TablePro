//
//  SQLFavoriteFolderScopeTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Issue #3045. A folder now carries a scope the user can set, and a folder is never narrower than
/// what it holds: making one available everywhere has to take its ancestors with it, and confining
/// one to a connection has to take its subfolders.
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

    // MARK: - Widening

    @Test("Making a subfolder global makes the folders above it global too")
    func wideningCarriesTheAncestorChain() async {
        let connectionId = UUID()
        let top = await store(SQLFavoriteFolder(name: "Reports", connectionId: connectionId))
        let middle = await store(SQLFavoriteFolder(name: "Weekly", parentId: top.id, connectionId: connectionId))
        let leaf = await store(SQLFavoriteFolder(name: "Counts", parentId: middle.id, connectionId: connectionId))

        let change = await storage.setFolderScope(id: leaf.id, connectionId: nil)

        #expect(Set(change.changedFolderIds) == Set([leaf.id, middle.id, top.id]))
        #expect(await storage.fetchFolder(id: top.id)?.connectionId == nil)
        #expect(await storage.fetchFolder(id: middle.id)?.connectionId == nil)
        #expect(await storage.fetchFolder(id: leaf.id)?.connectionId == nil)
    }

    @Test("Making a folder global leaves the folders inside it alone")
    func wideningLeavesDescendantsAlone() async {
        let connectionId = UUID()
        let top = await store(SQLFavoriteFolder(name: "Reports", connectionId: connectionId))
        let child = await store(SQLFavoriteFolder(name: "Weekly", parentId: top.id, connectionId: connectionId))

        let change = await storage.setFolderScope(id: top.id, connectionId: nil)

        #expect(change.changedFolderIds == [top.id])
        #expect(await storage.fetchFolder(id: child.id)?.connectionId == connectionId)
    }

    // MARK: - Narrowing

    @Test("Confining a folder to a connection confines the folders inside it")
    func narrowingCarriesTheSubtree() async {
        let connectionId = UUID()
        let top = await store(SQLFavoriteFolder(name: "Reports", connectionId: nil))
        let child = await store(SQLFavoriteFolder(name: "Weekly", parentId: top.id, connectionId: nil))
        let grandchild = await store(SQLFavoriteFolder(name: "Counts", parentId: child.id, connectionId: nil))

        let change = await storage.setFolderScope(id: top.id, connectionId: connectionId)

        #expect(Set(change.changedFolderIds) == Set([top.id, child.id, grandchild.id]))
        #expect(await storage.fetchFolder(id: grandchild.id)?.connectionId == connectionId)
    }

    @Test("Confining a folder leaves the folders above it alone")
    func narrowingLeavesAncestorsAlone() async {
        let connectionId = UUID()
        let top = await store(SQLFavoriteFolder(name: "Reports", connectionId: nil))
        let child = await store(SQLFavoriteFolder(name: "Weekly", parentId: top.id, connectionId: nil))

        _ = await storage.setFolderScope(id: child.id, connectionId: connectionId)

        #expect(await storage.fetchFolder(id: top.id)?.connectionId == nil)
    }

    /// The unique index on (keyword, connection_id) is the reason a folder scope change never
    /// rewrites a query's own scope: a query pulled into a connection that already holds its
    /// keyword would fail the write and roll the whole change back with nothing to show for it.
    @Test("A folder scope change never rewrites the scope of a query inside it")
    func aScopeChangeLeavesQueriesAlone() async {
        let connectionId = UUID()
        let folder = await store(SQLFavoriteFolder(name: "Reports", connectionId: nil))
        let query = SQLFavorite(name: "Counts", query: "SELECT 1", keyword: "cnt", folderId: folder.id)
        #expect(await storage.addFavorite(query))

        _ = await storage.setFolderScope(id: folder.id, connectionId: connectionId)

        #expect(await storage.fetchFavorite(id: query.id)?.connectionId == nil)
        #expect(await storage.fetchFavorite(id: query.id)?.folderId == folder.id)
    }

    // MARK: - Another connection's folders

    /// A connection may keep its own folder inside a global one, and that folder is invisible to
    /// everybody else. Walking the whole subtree regardless of scope meant confining the global
    /// parent from one connection quietly moved another connection's branch into it.
    @Test("Confining a global folder leaves a subfolder belonging to another connection alone")
    func narrowingStopsAtAnotherConnectionsFolder() async {
        let mine = UUID()
        let theirs = UUID()
        let shared = await store(SQLFavoriteFolder(name: "Shared", connectionId: nil))
        let foreign = await store(SQLFavoriteFolder(name: "Theirs", parentId: shared.id, connectionId: theirs))
        let beneathForeign = await store(SQLFavoriteFolder(name: "Deeper", parentId: foreign.id, connectionId: nil))

        let change = await storage.setFolderScope(id: shared.id, connectionId: mine)

        #expect(change.changedFolderIds == [shared.id])
        #expect(await storage.fetchFolder(id: foreign.id)?.connectionId == theirs)
        #expect(await storage.fetchFolder(id: beneathForeign.id)?.connectionId == nil)
    }

    @Test("Making a folder global stops at an ancestor belonging to another connection")
    func wideningStopsAtAnotherConnectionsAncestor() async {
        let mine = UUID()
        let theirs = UUID()
        let foreign = await store(SQLFavoriteFolder(name: "Theirs", connectionId: theirs))
        let ours = await store(SQLFavoriteFolder(name: "Ours", parentId: foreign.id, connectionId: mine))

        let change = await storage.setFolderScope(id: ours.id, connectionId: nil)

        #expect(change.changedFolderIds == [ours.id])
        #expect(await storage.fetchFolder(id: foreign.id)?.connectionId == theirs)
    }

    @Test("Making a folder global stops once an ancestor is already global")
    func wideningStopsAtAGlobalAncestor() async {
        let mine = UUID()
        let top = await store(SQLFavoriteFolder(name: "Shared", connectionId: nil))
        let ours = await store(SQLFavoriteFolder(name: "Ours", parentId: top.id, connectionId: mine))

        let change = await storage.setFolderScope(id: ours.id, connectionId: nil)

        #expect(change.changedFolderIds == [ours.id])
    }

    // MARK: - Nothing to do, and nothing there

    @Test("Setting the scope a folder already has changes nothing")
    func aNoOpScopeChangeReportsNothing() async {
        let connectionId = UUID()
        let folder = await store(SQLFavoriteFolder(name: "Reports", connectionId: connectionId))

        #expect(await storage.setFolderScope(id: folder.id, connectionId: connectionId).isEmpty)
    }

    @Test("Setting the scope of a folder that is no longer stored changes nothing")
    func aMissingFolderReportsNothing() async {
        #expect(await storage.setFolderScope(id: UUID(), connectionId: nil).isEmpty)
    }

    // MARK: - Cycles

    /// `parent_id` carries no foreign key and no check constraint, so a chain that loops is
    /// representable and a walk without a visited set does not end.
    @Test("Widening terminates when the parent chain loops")
    func wideningTerminatesOnACycle() async {
        let connectionId = UUID()
        let firstId = UUID()
        let secondId = UUID()
        await store(SQLFavoriteFolder(id: firstId, name: "First", parentId: secondId, connectionId: connectionId))
        await store(SQLFavoriteFolder(id: secondId, name: "Second", parentId: firstId, connectionId: connectionId))

        let change = await storage.setFolderScope(id: firstId, connectionId: nil)

        #expect(Set(change.changedFolderIds) == Set([firstId, secondId]))
    }

    @Test("Narrowing terminates when the parent chain loops")
    func narrowingTerminatesOnACycle() async {
        let connectionId = UUID()
        let firstId = UUID()
        let secondId = UUID()
        await store(SQLFavoriteFolder(id: firstId, name: "First", parentId: secondId, connectionId: nil))
        await store(SQLFavoriteFolder(id: secondId, name: "Second", parentId: firstId, connectionId: nil))

        let change = await storage.setFolderScope(id: firstId, connectionId: connectionId)

        #expect(Set(change.changedFolderIds) == Set([firstId, secondId]))
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
