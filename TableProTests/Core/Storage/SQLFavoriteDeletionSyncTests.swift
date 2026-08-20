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

    /// Nothing to remove is not a deletion, so it must not leave a tombstone that would delete a
    /// record another device still has.
    @Test("Deleting a connection with no favorites tombstones nothing")
    func nothingRemovedTombstonesNothing() async {
        await manager.removeFavoritesAndFolders(for: UUID())

        #expect(tombstonedIds(.favorite).isEmpty)
        #expect(tombstonedIds(.favoriteFolder).isEmpty)
    }
}
