//
//  SQLFavoriteRemoteApplyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@Suite("SQL favorite remote apply")
struct SQLFavoriteRemoteApplyTests {
    private let storage: SQLFavoriteStorage
    private let metadata: SyncMetadataStorage
    private let manager: SQLFavoriteManager
    private let connectionId = UUID()
    private let older = Date(timeIntervalSince1970: 1_000)
    private let newer = Date(timeIntervalSince1970: 2_000)

    init() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("sql_favorites_remote_\(UUID().uuidString).db")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        storage = SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        metadata = SyncMetadataStorage(
            userDefaults: UserDefaults(suiteName: "tablepro-favorite-remote-\(UUID().uuidString)") ?? .standard,
            prefix: "tests.\(UUID().uuidString)"
        )
        manager = SQLFavoriteManager(
            storage: storage,
            syncTracker: SyncChangeTracker(metadataStorage: metadata)
        )
    }

    private func favorite(
        _ name: String,
        keyword: String?,
        connectionId: UUID?,
        createdAt: Date,
        folderId: UUID? = nil
    ) -> SQLFavorite {
        SQLFavorite(
            name: name,
            query: "SELECT '\(name)'",
            keyword: keyword,
            folderId: folderId,
            connectionId: connectionId,
            createdAt: createdAt
        )
    }

    private func store(_ favorites: SQLFavorite...) async {
        for favorite in favorites {
            #expect(await storage.addFavorite(favorite))
        }
    }

    @Test("A synced favorite reusing a keyword the same pull deletes is stored with it")
    func deletionFreesTheKeywordFirst() async {
        let deleted = favorite("Old revenue", keyword: "rev", connectionId: connectionId, createdAt: older)
        let replacement = favorite("Revenue", keyword: "rev", connectionId: connectionId, createdAt: newer)
        await store(deleted)

        let outcome = await manager.applyRemote(
            RemoteSQLFavoriteBatch(favorites: [replacement], deletedFavoriteIds: [deleted.id])
        )

        #expect(outcome == .applied)
        #expect(await storage.fetchFavorite(id: deleted.id) == nil)
        #expect(await storage.fetchFavorite(id: replacement.id)?.keyword == "rev")
        #expect(metadata.dirtyIds(for: .favorite).isEmpty)
    }

    @Test("A newer synced favorite loses a keyword an older local one holds, and is pushed without it")
    func olderLocalFavoriteKeepsTheKeyword() async {
        let local = favorite("Here", keyword: "rev", connectionId: connectionId, createdAt: older)
        let incoming = favorite("There", keyword: "rev", connectionId: connectionId, createdAt: newer)
        await store(local)

        let outcome = await manager.applyRemote(RemoteSQLFavoriteBatch(favorites: [incoming]))

        #expect(outcome == .applied)
        #expect(await storage.fetchFavorite(id: local.id)?.keyword == "rev")
        #expect(await storage.fetchFavorite(id: incoming.id)?.keyword == nil)
        #expect(metadata.dirtyIds(for: .favorite) == Set([incoming.id.uuidString]))
    }

    @Test("An older synced favorite takes a keyword from a newer local one, which is pushed without it")
    func olderIncomingFavoriteTakesTheKeyword() async {
        let local = favorite("Here", keyword: "rev", connectionId: connectionId, createdAt: newer)
        let incoming = favorite("There", keyword: "rev", connectionId: connectionId, createdAt: older)
        await store(local)

        let outcome = await manager.applyRemote(RemoteSQLFavoriteBatch(favorites: [incoming]))

        #expect(outcome == .applied)
        #expect(await storage.fetchFavorite(id: incoming.id)?.keyword == "rev")
        #expect(await storage.fetchFavorite(id: local.id)?.keyword == nil)
        #expect(metadata.dirtyIds(for: .favorite) == Set([local.id.uuidString]))
    }

    @Test("Two favorites swapping keywords in one pull both keep what they were given")
    func swappedKeywordsBothLand() async {
        var first = favorite("First", keyword: "rev", connectionId: connectionId, createdAt: older)
        var second = favorite("Second", keyword: "cost", connectionId: connectionId, createdAt: newer)
        await store(first, second)
        first.keyword = "cost"
        second.keyword = "rev"

        let outcome = await manager.applyRemote(RemoteSQLFavoriteBatch(favorites: [first, second]))

        #expect(outcome == .applied)
        #expect(await storage.fetchFavorite(id: first.id)?.keyword == "cost")
        #expect(await storage.fetchFavorite(id: second.id)?.keyword == "rev")
        #expect(metadata.dirtyIds(for: .favorite).isEmpty)
    }

    @Test("A favorite the same pull both changed and deleted ends deleted")
    func deletionWinsOverAChangeInTheSamePull() async {
        let doomed = favorite("Doomed", keyword: nil, connectionId: connectionId, createdAt: older)
        await store(doomed)

        let outcome = await manager.applyRemote(
            RemoteSQLFavoriteBatch(favorites: [doomed], deletedFavoriteIds: [doomed.id])
        )

        #expect(outcome == .applied)
        #expect(await storage.fetchFavorite(id: doomed.id) == nil)
    }

    @Test("A favorite synced into a folder the same pull deletes moves up to that folder's parent")
    func folderDeletionRunsAfterTheArrivals() async {
        let parent = SQLFavoriteFolder(name: "Reports", connectionId: connectionId)
        let doomed = SQLFavoriteFolder(name: "Weekly", parentId: parent.id, connectionId: connectionId)
        #expect(await storage.addFolder(parent))
        #expect(await storage.addFolder(doomed))
        let arriving = favorite(
            "Signups",
            keyword: nil,
            connectionId: connectionId,
            createdAt: older,
            folderId: doomed.id
        )

        let outcome = await manager.applyRemote(
            RemoteSQLFavoriteBatch(favorites: [arriving], deletedFolderIds: [doomed.id])
        )

        #expect(outcome == .applied)
        #expect(await storage.fetchFolder(id: doomed.id) == nil)
        #expect(await storage.fetchFavorite(id: arriving.id)?.folderId == parent.id)
    }

    @Test("A favorite deleted on another Mac takes this Mac's unpushed mark with it")
    func remoteDeletionDropsTheDirtyMark() async {
        let doomed = favorite("Doomed", keyword: nil, connectionId: connectionId, createdAt: older)
        #expect(await manager.addFavorite(doomed))
        #expect(metadata.dirtyIds(for: .favorite) == Set([doomed.id.uuidString]))

        let outcome = await manager.applyRemote(RemoteSQLFavoriteBatch(deletedFavoriteIds: [doomed.id]))

        #expect(outcome == .applied)
        #expect(metadata.dirtyIds(for: .favorite).isEmpty)
        #expect(metadata.tombstones(for: .favorite).isEmpty)
    }

    @Test("A folder deleted on another Mac takes this Mac's unpushed mark with it")
    func remoteFolderDeletionDropsTheDirtyMark() async {
        let doomed = SQLFavoriteFolder(name: "Doomed", connectionId: connectionId)
        #expect(await manager.addFolder(doomed))
        #expect(metadata.dirtyIds(for: .favoriteFolder) == Set([doomed.id.uuidString]))

        let outcome = await manager.applyRemote(RemoteSQLFavoriteBatch(deletedFolderIds: [doomed.id]))

        #expect(outcome == .applied)
        #expect(metadata.dirtyIds(for: .favoriteFolder).isEmpty)
        #expect(metadata.tombstones(for: .favoriteFolder).isEmpty)
    }

    @Test("An empty batch writes nothing")
    func emptyBatchIsSkipped() async {
        #expect(await manager.applyRemote(RemoteSQLFavoriteBatch()) == .skipped)
    }

    @Test("A store that cannot be written reports the batch as failed")
    func unwritableStoreFails() async {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("sql_favorites_blocker_\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: blocker) }
        let broken = SQLFavoriteManager(
            storage: SQLFavoriteStorage(databaseURL: blocker.appendingPathComponent("sql_favorites.db")),
            syncTracker: SyncChangeTracker(metadataStorage: metadata)
        )
        let incoming = favorite("Revenue", keyword: "rev", connectionId: connectionId, createdAt: older)

        #expect(await broken.applyRemote(RemoteSQLFavoriteBatch(favorites: [incoming])) == .failed)
    }
}
