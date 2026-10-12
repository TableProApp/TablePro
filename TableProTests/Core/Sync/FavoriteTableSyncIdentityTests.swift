import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct FavoriteTableSyncIdentityTests {
    private static let zoneID = SyncTestEnvironment.zoneID
    private static let storageKey = "com.TablePro.favoriteTables"

    private let environment: SyncTestEnvironment
    private let connectionId = UUID()

    init() throws {
        environment = try SyncTestEnvironment(label: "favorite-table-identity")
    }

    private var tables: FavoriteTablesStorage { environment.favoriteTables }
    private var tracker: SyncChangeTracker { environment.tracker }

    private var pipedEntry: FavoriteTablesStorage.FavoriteEntry {
        FavoriteTablesStorage.FavoriteEntry(connectionId: connectionId, database: "shop", schema: "a|b", name: "orders")
    }

    private func storeBeforeUpgrade(_ entries: [FavoriteTablesStorage.FavoriteEntry]) throws {
        environment.defaults.set(try JSONEncoder().encode(entries), forKey: Self.storageKey)
    }

    private func recordID(_ id: String) -> CKRecord.ID {
        SyncRecordMapper.recordID(type: .tableFavorite, id: id, in: Self.zoneID)
    }

    private func aliasId(of entry: FavoriteTablesStorage.FavoriteEntry) throws -> String {
        try #require(FavoriteTablesStorage.legacyAlias(of: entry))
    }

    private func legacyRecord(for entry: FavoriteTablesStorage.FavoriteEntry) throws -> CKRecord {
        let current = SyncRecordMapper.toCKRecord(favoriteEntry: entry, in: Self.zoneID)
        let legacy = CKRecord(recordType: current.recordType, recordID: recordID(try aliasId(of: entry)))
        for key in current.allKeys() {
            legacy[key] = current[key]
        }
        return legacy
    }

    private func echoEverything() -> ScriptedSyncTransport {
        ScriptedSyncTransport(zoneID: Self.zoneID) { records, deletions in
            PullResult(changedRecords: records, deletedRecordIDs: deletions, newToken: nil)
        }
    }

    @Test("A favorite re-keyed at launch survives the echo of its own push")
    func migratedFavoriteSurvivesItsEcho() async throws {
        try storeBeforeUpgrade([pipedEntry])
        tables.migrateSyncIdentityIfNeeded()
        let transport = echoEverything()

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(tables.favorites(for: connectionId) == [pipedEntry])
        let alias = try aliasId(of: pipedEntry)
        #expect(
            Set(await transport.pushedRecords.map(\.recordID))
                == [recordID(FavoriteTablesStorage.syncId(for: pipedEntry)), recordID(alias)]
        )
        #expect(await transport.pushedDeletions.isEmpty)
        #expect(tracker.tombstonedIds(for: .tableFavorite).isEmpty)
        #expect(tracker.dirtyRecords(for: .tableFavorite).isEmpty)
    }

    @Test("A favorite starred after the upgrade is also saved under its old id, for Macs on an older build")
    func postUpgradeFavoriteIsSavedUnderBothIds() async throws {
        tables.addFavorite(name: "orders", schema: "a|b", database: "shop", connectionId: connectionId)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        let pushed = await transport.pushedRecords
        let aliasRecordID = recordID(try aliasId(of: pipedEntry))
        let alias = try #require(pushed.first { $0.recordID == aliasRecordID })
        #expect(failure == nil)
        #expect(pushed.count == 2)
        #expect(try SyncRecordMapper.favoriteEntry(from: alias) == pipedEntry)
        #expect(tracker.dirtyRecords(for: .tableFavorite).isEmpty)
    }

    @Test("Two favorites that share an old id are saved under their new ids alone")
    func sharedOldIdIsNotPublished() async throws {
        tables.addFavorite(name: "t", schema: "c", database: "a|b", connectionId: connectionId)
        tables.addFavorite(name: "t", schema: "b|c", database: "a", connectionId: connectionId)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        let ids = Set(tables.favorites(for: connectionId).map { recordID(FavoriteTablesStorage.syncId(for: $0)) })
        #expect(failure == nil)
        #expect(Set(await transport.pushedRecords.map(\.recordID)) == ids)
        #expect(tracker.dirtyRecords(for: .tableFavorite).isEmpty)
    }

    @Test("Removing one of two favorites that shared an old id republishes that id for the one left")
    func sharedOldIdIsRepublishedForTheSurvivor() async throws {
        tables.addFavorite(name: "t", schema: "c", database: "a|b", connectionId: connectionId)
        tables.addFavorite(name: "t", schema: "b|c", database: "a", connectionId: connectionId)
        _ = await environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID)).runSyncCycle()
        let survivor = FavoriteTablesStorage.FavoriteEntry(connectionId: connectionId, database: "a", schema: "b|c", name: "t")
        let alias = try aliasId(of: survivor)

        tables.removeFavorite(name: "t", schema: "c", database: "a|b", connectionId: connectionId)
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)
        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        let aliasRecordID = recordID(alias)
        let republished = try #require(await transport.pushedRecords.first { $0.recordID == aliasRecordID })
        #expect(failure == nil)
        #expect(try SyncRecordMapper.favoriteEntry(from: republished) == survivor)
        #expect(!(await transport.pushedDeletions.contains(aliasRecordID)))
        #expect(tracker.dirtyRecords(for: .tableFavorite).isEmpty)
    }

    @Test("A re-keyed favorite starred again while its deletion is in flight survives the echo under both ids")
    func restarOfARekeyedFavoriteDuringTheDeletionSurvives() async throws {
        let storage = tables
        let owner = connectionId
        storage.addFavorite(name: "orders", schema: "a|b", database: "shop", connectionId: owner)
        environment.metadata.clearDirty(type: .tableFavorite)
        storage.removeFavorite(name: "orders", schema: "a|b", database: "shop", connectionId: owner)
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            duringPush: { storage.addFavorite(name: "orders", schema: "a|b", database: "shop", connectionId: owner) },
            echoing: { records, deletions in PullResult(changedRecords: records, deletedRecordIDs: deletions, newToken: nil) }
        )

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(await transport.pushedDeletions.count == 2)
        #expect(tables.favorites(for: connectionId) == [pipedEntry])
        #expect(tracker.tombstonedIds(for: .tableFavorite).isEmpty)
        let alias = try aliasId(of: pipedEntry)
        #expect(tracker.dirtyRecords(for: .tableFavorite) == [FavoriteTablesStorage.syncId(for: pipedEntry), alias])
    }

    @Test("A favorite starred again just before the upgrade survives the first sync after it")
    func restarredBeforeUpgradeSurvives() async throws {
        try storeBeforeUpgrade([pipedEntry])
        let legacyId = try aliasId(of: pipedEntry)
        tracker.markDeleted(.tableFavorite, id: legacyId)
        tracker.markDirty(.tableFavorite, id: legacyId)
        tables.migrateSyncIdentityIfNeeded()
        let transport = echoEverything()

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(tables.favorites(for: connectionId) == [pipedEntry])
        #expect(await transport.pushedDeletions.isEmpty)
        #expect(tracker.tombstonedIds(for: .tableFavorite).isEmpty)
        #expect(tracker.dirtyRecords(for: .tableFavorite).isEmpty)
    }

    @Test("A Mac on an older build deleting a favorite starred after the upgrade removes it too")
    func legacyDeletionOfAPostUpgradeFavorite() async throws {
        tables.migrateSyncIdentityIfNeeded()
        tables.addFavorite(name: "orders", schema: "a|b", database: "shop", connectionId: connectionId)
        environment.metadata.clearDirty(type: .tableFavorite)
        let alias = try aliasId(of: pipedEntry)

        let acknowledged = await environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
            .applyPullResult(PullResult(changedRecords: [], deletedRecordIDs: [recordID(alias)], newToken: nil))

        #expect(acknowledged)
        #expect(tables.favorites(for: connectionId).isEmpty)
        #expect(tracker.tombstonedIds(for: .tableFavorite) == [FavoriteTablesStorage.syncId(for: pipedEntry)])
    }

    @Test("A favorite starred again while its deletion is in flight survives the echo of that deletion")
    func restarDuringTheDeletionSurvivesItsEcho() async throws {
        let entry = FavoriteTablesStorage.FavoriteEntry(connectionId: connectionId, database: "shop", schema: nil, name: "orders")
        let storage = tables
        storage.addFavorite(name: "orders", schema: nil, database: "shop", connectionId: connectionId)
        environment.metadata.clearDirty(type: .tableFavorite)
        storage.removeFavorite(name: "orders", schema: nil, database: "shop", connectionId: connectionId)
        let transport = ScriptedSyncTransport(
            zoneID: Self.zoneID,
            duringPush: { storage.addFavorite(name: "orders", schema: nil, database: "shop", connectionId: entry.connectionId) },
            echoing: { records, deletions in PullResult(changedRecords: records, deletedRecordIDs: deletions, newToken: nil) }
        )

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        let id = FavoriteTablesStorage.syncId(for: entry)
        #expect(failure == nil)
        #expect(await transport.pushedDeletions == [recordID(id)])
        #expect(tables.favorites(for: connectionId) == [entry])
        #expect(tracker.dirtyRecords(for: .tableFavorite) == [id])

        let next = ScriptedSyncTransport(zoneID: Self.zoneID)
        _ = await environment.makeCoordinator(transport: next).runSyncCycle()

        #expect(await next.pushedRecords.map(\.recordID) == [recordID(id)])
        #expect(await next.pushedDeletions.isEmpty)
    }

    @Test("A favorite saved in the same pull that deletes its connection is not kept")
    func connectionDeletionOutranksAFavoriteSave() async throws {
        let connection = TestFixtures.makeConnection(name: "Removed")
        environment.connections.addConnection(connection)
        let favorite = FavoriteTablesStorage.FavoriteEntry(
            connectionId: connection.id, database: "shop", schema: nil, name: "orders"
        )

        let acknowledged = await environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
            .applyPullResult(PullResult(
                changedRecords: [SyncRecordMapper.toCKRecord(favoriteEntry: favorite, in: Self.zoneID)],
                deletedRecordIDs: [
                    SyncRecordMapper.recordID(type: .connection, id: connection.id.uuidString, in: Self.zoneID)
                ],
                newToken: nil
            ))

        #expect(acknowledged)
        #expect(environment.connections.loadConnection(id: connection.id) == nil)
        #expect(tables.favorites(for: connection.id).isEmpty)
        #expect(tracker.tombstonedIds(for: .tableFavorite).isEmpty)
    }

    @Test("A Mac on an older build deleting the favorite by its old id removes it and retires the new id")
    func legacyDeletionRemovesTheFavorite() async throws {
        try storeBeforeUpgrade([pipedEntry])
        tables.migrateSyncIdentityIfNeeded()
        let legacyId = try aliasId(of: pipedEntry)

        let acknowledged = await environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
            .applyPullResult(PullResult(changedRecords: [], deletedRecordIDs: [recordID(legacyId)], newToken: nil))

        #expect(acknowledged)
        #expect(tables.favorites(for: connectionId).isEmpty)
        #expect(tracker.tombstonedIds(for: .tableFavorite) == [FavoriteTablesStorage.syncId(for: pipedEntry)])
        #expect(tracker.dirtyRecords(for: .tableFavorite).isEmpty)
    }

    @Test("Removing a re-keyed favorite deletes both of its records, and their echo changes nothing")
    func localRemovalDeletesBothRecords() async throws {
        try storeBeforeUpgrade([pipedEntry])
        tables.migrateSyncIdentityIfNeeded()
        tables.removeFavorite(name: "orders", schema: "a|b", database: "shop", connectionId: connectionId)
        let currentId = FavoriteTablesStorage.syncId(for: pipedEntry)
        let legacyId = try aliasId(of: pipedEntry)
        #expect(tracker.tombstonedIds(for: .tableFavorite) == [currentId, legacyId])
        let transport = echoEverything()

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == nil)
        #expect(Set(await transport.pushedDeletions) == [recordID(currentId), recordID(legacyId)])
        #expect(tables.favorites(for: connectionId).isEmpty)
        #expect(tracker.tombstonedIds(for: .tableFavorite).isEmpty)
        #expect(tracker.dirtyRecords(for: .tableFavorite).isEmpty)
    }

    @Test("A favorite pulled from a Mac on an older build is deleted under both ids when removed here")
    func pulledLegacyRecordIsRetiredOnRemoval() async throws {
        let acknowledged = await environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
            .applyPullResult(PullResult(changedRecords: [try legacyRecord(for: pipedEntry)], deletedRecordIDs: [], newToken: nil))
        #expect(acknowledged)
        #expect(tables.favorites(for: connectionId) == [pipedEntry])

        let legacyId = try aliasId(of: pipedEntry)

        tables.removeFavorite(name: "orders", schema: "a|b", database: "shop", connectionId: connectionId)

        #expect(tracker.tombstonedIds(for: .tableFavorite) == [FavoriteTablesStorage.syncId(for: pipedEntry), legacyId])
    }

    @Test("A pull applies all of its table favorite saves and deletions as one change")
    func pullAppliesTableFavoritesAsOneChange() async throws {
        let kept = FavoriteTablesStorage.FavoriteEntry(connectionId: connectionId, database: "shop", schema: nil, name: "kept")
        let doomed = ["gone_1", "gone_2"].map {
            FavoriteTablesStorage.FavoriteEntry(connectionId: connectionId, database: "shop", schema: nil, name: $0)
        }
        try storeBeforeUpgrade([kept] + doomed)
        let arriving = ["new_1", "new_2", "new_3"].map {
            FavoriteTablesStorage.FavoriteEntry(connectionId: connectionId, database: "shop", schema: nil, name: $0)
        }
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .favoriteTablesDidChange, object: tables, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let acknowledged = await environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
            .applyPullResult(PullResult(
                changedRecords: arriving.map { SyncRecordMapper.toCKRecord(favoriteEntry: $0, in: Self.zoneID) },
                deletedRecordIDs: doomed.map { recordID(FavoriteTablesStorage.syncId(for: $0)) },
                newToken: nil
            ))

        #expect(acknowledged)
        #expect(notifications == 1)
        #expect(tables.favorites(for: connectionId) == Set([kept] + arriving))
        #expect(tracker.tombstonedIds(for: .tableFavorite).isEmpty)
        #expect(tracker.dirtyRecords(for: .tableFavorite).isEmpty)
    }
}
