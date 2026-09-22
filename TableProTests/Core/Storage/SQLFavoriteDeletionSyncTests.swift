//
//  SQLFavoriteDeletionSyncTests.swift
//  TableProTests
//
//  Deleting a connection has to tombstone its SQL favorites and folders like every other delete
//  path does. It was the one delete keyed on something other than the records themselves, so it
//  could not name them, never marked them deleted, and left them in CloudKit for good.
//

import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@Suite("SQL favorite deletion sync")
struct SQLFavoriteDeletionSyncTests {
    private let storage: SQLFavoriteStorage
    private let metadata: SyncMetadataStorage
    private let manager: SQLFavoriteManager

    init() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("sql_favorites_sync_\(UUID().uuidString).db")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        storage = SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        metadata = SyncMetadataStorage(
            userDefaults: UserDefaults(suiteName: "tablepro-favorite-sync-\(UUID().uuidString)") ?? .standard,
            prefix: "tests.\(UUID().uuidString)"
        )
        manager = SQLFavoriteManager(
            storage: storage,
            syncTracker: SyncChangeTracker(metadataStorage: metadata)
        )
    }

    private func tombstonedIds(_ type: SyncRecordType) -> Set<String> {
        Set(metadata.tombstones(for: type).map(\.id))
    }

    /// When the other device did the deleting, a tombstone here pushes its own deletion straight
    /// back at it. The rows still go.
    @Test("A remote delete removes the rows and tombstones nothing")
    func remoteDeleteLeavesNoTombstone() async {
        let connectionId = UUID()
        let folder = SQLFavoriteFolder(name: "Reports", connectionId: connectionId)
        let favorite = SQLFavorite(
            name: "Active users",
            query: "SELECT * FROM users",
            folderId: folder.id,
            connectionId: connectionId
        )
        #expect(await manager.addFolder(folder))
        #expect(await manager.addFavorite(favorite))

        await manager.removeFavoritesAndFoldersWithoutSync(for: connectionId)

        #expect(!tombstonedIds(.favorite).contains(favorite.id.uuidString))
        #expect(!tombstonedIds(.favoriteFolder).contains(folder.id.uuidString))
        #expect(await manager.fetchFavorites(connectionId: connectionId).isEmpty)
    }

    /// Without this the id stays dirty for good: the next push looks for a record that is gone,
    /// skips it, and nothing ever drains the entry.
    @Test("A remote delete drains the dirty marks of what it removed")
    func remoteDeleteDrainsDirtyMarks() async {
        let connectionId = UUID()
        let favorite = SQLFavorite(
            name: "Active users", query: "SELECT * FROM users", connectionId: connectionId
        )
        #expect(await manager.addFavorite(favorite))
        #expect(metadata.dirtyIds(for: .favorite).contains(favorite.id.uuidString))

        await manager.removeFavoritesAndFoldersWithoutSync(for: connectionId)

        #expect(!metadata.dirtyIds(for: .favorite).contains(favorite.id.uuidString))
    }

    @Test("A remote delete with nothing to remove tombstones nothing")
    func remoteDeleteOfNothingTombstonesNothing() async {
        await manager.removeFavoritesAndFoldersWithoutSync(for: UUID())

        #expect(tombstonedIds(.favorite).isEmpty)
        #expect(tombstonedIds(.favoriteFolder).isEmpty)
    }

    @Test("Deleting a connection tombstones its favorites and its folders")
    func connectionDeleteTombstonesEverythingItRemoved() async {
        let connectionId = UUID()
        let folder = SQLFavoriteFolder(name: "Reports", connectionId: connectionId)
        let favorite = SQLFavorite(
            name: "Active users",
            query: "SELECT * FROM users",
            folderId: folder.id,
            connectionId: connectionId
        )
        #expect(await manager.addFolder(folder))
        #expect(await manager.addFavorite(favorite))

        await manager.removeFavoritesAndFolders(for: connectionId)

        #expect(tombstonedIds(.favorite).contains(favorite.id.uuidString))
        #expect(tombstonedIds(.favoriteFolder).contains(folder.id.uuidString))
    }

    /// The delete is keyed on the connection, so it must leave another connection's records, and
    /// their sync state, untouched.
    @Test("Another connection's favorites are neither deleted nor tombstoned")
    func aDifferentConnectionIsUntouched() async {
        let doomed = UUID()
        let kept = UUID()
        let doomedFavorite = SQLFavorite(name: "Doomed", query: "SELECT 1", connectionId: doomed)
        let keptFavorite = SQLFavorite(name: "Kept", query: "SELECT 2", connectionId: kept)
        #expect(await manager.addFavorite(doomedFavorite))
        #expect(await manager.addFavorite(keptFavorite))

        await manager.removeFavoritesAndFolders(for: doomed)

        #expect(tombstonedIds(.favorite).contains(doomedFavorite.id.uuidString))
        #expect(!tombstonedIds(.favorite).contains(keptFavorite.id.uuidString))
        #expect(await manager.fetchFavorite(id: keptFavorite.id) != nil)
    }

    /// A global subfolder inside a deleted connection's folder survives the delete, and the delete
    /// has to clear the parent it can no longer resolve. That rewrite is a local edit, so it has to
    /// be pushed: without the mark this Mac drew the survivor at the root while every other device
    /// and every fresh install still had it pointing at a folder that no longer exists.
    @Test("A folder that outlives its parent is marked for the next push")
    func aDetachedFolderIsMarkedDirty() async {
        let connectionId = UUID()
        let owned = SQLFavoriteFolder(name: "Acme", connectionId: connectionId)
        let survivor = SQLFavoriteFolder(name: "Shared", parentId: owned.id, connectionId: nil)
        let survivingQuery = SQLFavorite(
            name: "Counts",
            query: "SELECT 1",
            folderId: owned.id,
            connectionId: nil
        )
        #expect(await manager.addFolder(owned))
        #expect(await manager.addFolder(survivor))
        #expect(await manager.addFavorite(survivingQuery))
        metadata.clearDirty(type: .favoriteFolder)
        metadata.clearDirty(type: .favorite)

        await manager.removeFavoritesAndFolders(for: connectionId)

        #expect(await manager.fetchFolder(id: survivor.id)?.parentId == nil)
        #expect(await manager.fetchFavorite(id: survivingQuery.id)?.folderId == nil)
        #expect(metadata.dirtyIds(for: .favoriteFolder).contains(survivor.id.uuidString))
        #expect(metadata.dirtyIds(for: .favorite).contains(survivingQuery.id.uuidString))
        #expect(!tombstonedIds(.favoriteFolder).contains(survivor.id.uuidString))
    }

    /// Nothing to remove is not a deletion, so it must not leave a tombstone that would delete a
    /// record another device still has.
    @Test("Deleting a connection with no favorites tombstones nothing")
    func nothingRemovedTombstonesNothing() async {
        await manager.removeFavoritesAndFolders(for: UUID())

        #expect(tombstonedIds(.favorite).isEmpty)
        #expect(tombstonedIds(.favoriteFolder).isEmpty)
    }

    // MARK: - Deleting a folder moves what was inside it

    /// The rows a folder delete reparents are written, so they have to be pushed. Only the folder
    /// used to be told to sync, and the moved records kept the deleted folder's id on the wire.
    @Test("Deleting a folder marks the records it moved up a level")
    func deletingAFolderMarksWhatItMoved() async {
        let connectionId = UUID()
        let folder = SQLFavoriteFolder(name: "Reports", connectionId: connectionId)
        let subfolder = SQLFavoriteFolder(name: "Weekly", parentId: folder.id, connectionId: connectionId)
        let favorite = SQLFavorite(
            name: "Active users",
            query: "SELECT * FROM users",
            folderId: folder.id,
            connectionId: connectionId
        )
        #expect(await manager.addFolder(folder))
        #expect(await manager.addFolder(subfolder))
        #expect(await manager.addFavorite(favorite))
        metadata.clearDirty(type: .favorite)
        metadata.clearDirty(type: .favoriteFolder)

        #expect(await manager.deleteFolder(id: folder.id))

        #expect(tombstonedIds(.favoriteFolder).contains(folder.id.uuidString))
        #expect(metadata.dirtyIds(for: .favorite).contains(favorite.id.uuidString))
        #expect(metadata.dirtyIds(for: .favoriteFolder).contains(subfolder.id.uuidString))
    }

    /// The other device already made this move and pushed it, so marking the moved rows here would
    /// send its own change back to it.
    @Test("A remote folder delete marks nothing it moved")
    func aRemoteFolderDeleteMarksNothing() async {
        let connectionId = UUID()
        let folder = SQLFavoriteFolder(name: "Reports", connectionId: connectionId)
        let favorite = SQLFavorite(
            name: "Active users",
            query: "SELECT * FROM users",
            folderId: folder.id,
            connectionId: connectionId
        )
        #expect(await manager.addFolder(folder))
        #expect(await manager.addFavorite(favorite))
        metadata.clearDirty(type: .favorite)
        metadata.clearDirty(type: .favoriteFolder)

        await manager.applyRemoteDeleteFolder(id: folder.id)

        #expect(metadata.dirtyIds(for: .favorite).isEmpty)
        #expect(tombstonedIds(.favoriteFolder).isEmpty)
    }
}
