import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncPushSettlementTests {
    private static let zoneID = SyncTestEnvironment.zoneID

    private let environment: SyncTestEnvironment

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-push-settlement")
    }

    private var tracker: SyncChangeTracker { environment.tracker }
    private var metadata: SyncMetadataStorage { environment.metadata }

    private func tableFavoriteRecordID(_ entry: FavoriteTablesStorage.FavoriteEntry) -> CKRecord.ID {
        SyncRecordMapper.recordID(type: .tableFavorite, id: FavoriteTablesStorage.syncId(for: entry), in: Self.zoneID)
    }

    @Test("A table starred again before the push is sent as a save alone, and its tombstone clears")
    func restarredFavoriteIsSavedNotDeleted() async throws {
        let connectionId = UUID()
        let tables = environment.favoriteTables
        tables.toggle(name: "orders", schema: "public", database: "shop", connectionId: connectionId)
        tables.toggle(name: "orders", schema: "public", database: "shop", connectionId: connectionId)
        tables.toggle(name: "orders", schema: "public", database: "shop", connectionId: connectionId)
        let entry = FavoriteTablesStorage.FavoriteEntry(
            connectionId: connectionId, database: "shop", schema: "public", name: "orders"
        )
        let id = FavoriteTablesStorage.syncId(for: entry)
        #expect(tracker.dirtyRecords(for: .tableFavorite) == [id])
        #expect(tracker.tombstonedIds(for: .tableFavorite) == [id])
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(await transport.pushedRecords.map(\.recordID) == [tableFavoriteRecordID(entry)])
        #expect(await transport.pushedDeletions.isEmpty)
        #expect(tracker.dirtyRecords(for: .tableFavorite).isEmpty)
        #expect(tracker.tombstonedIds(for: .tableFavorite).isEmpty)
    }

    @Test("A record marked dirty and then tombstoned while it still exists is sent as a save alone")
    func dirtyThenTombstonedExistingRecordIsSaved() async throws {
        let tag = ConnectionTag(name: "staging")
        try environment.tags.addTag(tag)
        metadata.addTombstone(tag.id.uuidString, type: .tag)
        let recordID = SyncRecordMapper.recordID(type: .tag, id: tag.id.uuidString, in: Self.zoneID)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(await transport.pushedRecords.map(\.recordID).contains(recordID))
        #expect(await transport.pushedDeletions.isEmpty)
        #expect(tracker.tombstonedIds(for: .tag).isEmpty)
        #expect(environment.tags.tag(for: tag.id) != nil)
    }

    @Test("A record both dirty and tombstoned that no longer exists is sent as a deletion alone")
    func dirtyAndTombstonedAbsentRecordIsDeleted() async throws {
        let absent = UUID().uuidString
        tracker.markDeleted(.tag, id: absent)
        tracker.markDirty(.tag, id: absent)
        let recordID = SyncRecordMapper.recordID(type: .tag, id: absent, in: Self.zoneID)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(await transport.pushedRecords.isEmpty)
        #expect(await transport.pushedDeletions == [recordID])
        #expect(tracker.dirtyRecords(for: .tag).isEmpty)
        #expect(tracker.tombstonedIds(for: .tag).isEmpty)
    }

    @Test("A table favorite unstarred again while its save is in flight keeps its tombstone for the next push")
    func deletionDuringTheSaveKeepsTheTombstone() async throws {
        let connectionId = UUID()
        let tables = environment.favoriteTables
        tables.toggle(name: "orders", schema: nil, database: "shop", connectionId: connectionId)
        tables.toggle(name: "orders", schema: nil, database: "shop", connectionId: connectionId)
        tables.toggle(name: "orders", schema: nil, database: "shop", connectionId: connectionId)
        let entry = FavoriteTablesStorage.FavoriteEntry(
            connectionId: connectionId, database: "shop", schema: nil, name: "orders"
        )
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            duringPush: { tables.toggle(name: "orders", schema: nil, database: "shop", connectionId: connectionId) }
        )

        _ = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(tables.favorites(for: connectionId).isEmpty)
        #expect(tracker.tombstonedIds(for: .tableFavorite) == [FavoriteTablesStorage.syncId(for: entry)])
        #expect(tracker.dirtyRecords(for: .tableFavorite).isEmpty)

        let next = ScriptedSyncTransport(zoneID: Self.zoneID)
        _ = await environment.makeCoordinator(transport: next).runSyncCycle()

        #expect(await next.pushedDeletions == [tableFavoriteRecordID(entry)])
        #expect(tracker.tombstonedIds(for: .tableFavorite).isEmpty)
    }

    @Test("A deletion withheld while its store cannot be read keeps both marks")
    func unreadableStoreWithholdsTheConflictedDeletion() async throws {
        let url = environment.directory.appendingPathComponent("not-a-database.db")
        try Data(repeating: 0x2A, count: 4_096).write(to: url)
        let broken = SQLFavoriteManager(
            storage: SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true),
            syncTracker: tracker
        )
        let id = UUID().uuidString
        tracker.markDeleted(.favorite, id: id)
        tracker.markDirty(.favorite, id: id)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        _ = await environment.makeCoordinator(transport: transport, favorites: broken).runSyncCycle()

        #expect(await transport.pushedDeletions.isEmpty)
        #expect(tracker.dirtyRecords(for: .favorite).contains(id))
        #expect(tracker.tombstonedIds(for: .favorite).contains(id))
    }

    @Test("A deletion of a record iCloud never had clears its tombstone and fails nothing")
    func missingDeletionSettles() async throws {
        let absent = UUID().uuidString
        tracker.markDeleted(.tag, id: absent)
        let recordID = SyncRecordMapper.recordID(type: .tag, id: absent, in: Self.zoneID)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID, missing: [recordID])

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(await transport.pushedDeletions == [recordID])
        #expect(tracker.tombstonedIds(for: .tag).isEmpty)
    }

    @Test("A database renamed and renamed back before a push saves the original and deletes only the detour")
    func databaseFavoriteRoundTripSavesTheOriginal() async throws {
        let connectionId = UUID()
        let databases = environment.favoriteDatabases
        databases.setFavorite(database: "shop", environment: .production, connectionId: connectionId)
        metadata.clearDirty(type: .favoriteDatabase)
        databases.rename(database: "shop", to: "shop_v2", connectionId: connectionId)
        databases.rename(database: "shop_v2", to: "shop", connectionId: connectionId)
        let original = FavoriteDatabaseEntry(connectionId: connectionId, database: "shop", environment: .production)
        let detour = FavoriteDatabaseEntry(connectionId: connectionId, database: "shop_v2", environment: .production)
        let originalID = SyncRecordMapper.recordID(
            type: .favoriteDatabase, id: FavoriteDatabasesStorage.syncId(for: original), in: Self.zoneID
        )
        let detourID = SyncRecordMapper.recordID(
            type: .favoriteDatabase, id: FavoriteDatabasesStorage.syncId(for: detour), in: Self.zoneID
        )
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(databases.favorites(for: connectionId) == [original])
        #expect(await transport.pushedRecords.map(\.recordID) == [originalID])
        #expect(await transport.pushedDeletions == [detourID])
        #expect(tracker.dirtyRecords(for: .favoriteDatabase).isEmpty)
        #expect(tracker.tombstonedIds(for: .favoriteDatabase).isEmpty)
    }
}
