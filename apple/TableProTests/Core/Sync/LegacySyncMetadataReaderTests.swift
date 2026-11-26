import CloudKit
import Foundation
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import Testing

struct LegacySyncMetadataReaderTests {
    private let suite: EphemeralDefaults
    private let metadata: SyncMetadataStorage
    private let directory: URL
    private let cache: SyncRecordCache

    init() throws {
        suite = try EphemeralDefaults("LegacySyncMetadataReaderTests")
        metadata = SyncMetadataStorage(userDefaults: suite.defaults)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacySyncMetadataReaderTests-\(UUID().uuidString)", isDirectory: true)
        cache = SyncRecordCache(directory: directory, defaults: nil)
    }

    private var reader: LegacySyncMetadataReader {
        LegacySyncMetadataReader(metadata: metadata, recordCache: cache)
    }

    @Test("A device the Swift engine never synced imports nothing")
    func nothingRecorded() {
        let read = reader.read()

        #expect(read.token == nil)
        #expect(read.dirty.isEmpty)
        #expect(read.tombstones.isEmpty)
        #expect(read.cache.isEmpty)
        #expect(read.changesHeldForUnreadable.isEmpty)
        #expect(read.removalsPendingForUnreadable.isEmpty)
        #expect(read.deletionsHeldForUnreadable.isEmpty)
        #expect(read.account == nil)
        #expect(read.zoneState == SyncZoneState.unknown.rawValue)
        #expect(read.readableRecordTypes.isEmpty)
    }

    @Test("The dirty and tombstone keys, the held and deferred sets, owners kept off sync and the account come across as kept")
    func keysAndSets() throws {
        let owner = UUID()
        let deletedAt = Date(timeIntervalSince1970: 1_767_225_600)
        metadata.markDirty(["B", "A"], type: .connection)
        metadata.markDirty("S1", type: .settings)
        metadata.addTombstones([Tombstone(id: "G1", deletedAt: deletedAt)], type: .group)
        metadata.addTombstones([Tombstone(id: "F1", deletedAt: deletedAt, owner: owner)], type: .tableFavorite)
        metadata.deferredDeletions = ["Favorite_X", "Connection_Y"]
        metadata.changesHeldForUnreadableCopies = ["Connection_C"]
        metadata.removalsPendingForUnreadableCopies = ["Group_R"]
        metadata.deletionsHeldForUnreadableCopies = ["Connection_D"]
        metadata.keepOffSync(owners: [owner])
        metadata.lastAccountId = "_alice"
        metadata.zoneState = .removed
        _ = metadata.adoptReadableRecordTypes(["Connection", "ConnectionGroup"])

        let read = reader.read()

        #expect(read.dirty == [
            LegacyRecordArg(recordType: "Connection", id: "A"),
            LegacyRecordArg(recordType: "Connection", id: "B"),
            LegacyRecordArg(recordType: "AppSettings", id: "S1")
        ])
        #expect(Set(read.tombstones) == [
            LegacyTombstoneArg(
                record: LegacyRecordArg(recordType: "ConnectionGroup", id: "G1"),
                deletedAtMs: 1_767_225_600_000,
                owner: nil
            ),
            LegacyTombstoneArg(
                record: LegacyRecordArg(recordType: "FavoriteTable", id: "F1"),
                deletedAtMs: 1_767_225_600_000,
                owner: owner.uuidString
            )
        ])
        #expect(read.deferredDeletions == ["Connection_Y", "Favorite_X"])
        #expect(read.changesHeldForUnreadable == ["Connection_C"])
        #expect(read.removalsPendingForUnreadable == ["Group_R"])
        #expect(read.deletionsHeldForUnreadable == ["Connection_D"])
        #expect(read.ownersKeptOffSync == [owner.uuidString])
        #expect(read.account == "_alice")
        #expect(read.zoneState == "removed")
        #expect(read.readableRecordTypes == ["Connection", "ConnectionGroup"])
    }

    @Test("Standing comes across by connection, Local only winning over a stale syncs")
    func standing() {
        let syncs = UUID()
        let localOnly = UUID()
        metadata.recordConnectionStanding(syncing: [syncs, localOnly], keptOff: [localOnly], unreadable: [])

        let read = reader.read()

        #expect(Set(read.standing) == [
            LegacyStandingArg(connection: syncs.uuidString, standing: .syncs),
            LegacyStandingArg(connection: localOnly.uuidString, standing: .localOnly)
        ])
    }

    @Test("Each cached record comes across with its fields and system fields, as the engine's base")
    func cachedRecordsAreBases() throws {
        let zone = CKRecordZone.ID(zoneName: CloudKitSyncEngine.zoneName, ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "ConnectionTag", recordID: CKRecord.ID(recordName: "Tag_A", zoneID: zone))
        record["name"] = "Production"
        cache.store([record])

        let base = try #require(reader.read().cache.first)

        #expect(base.recordType == "ConnectionTag")
        #expect(base.name == "Tag_A")
        #expect(base.fields == [CloudKitField(name: "name", value: .text(value: "Production"))])
        let rebuilt = try #require(base.systemFields.flatMap(CloudKitRecordConversion.rebuild))
        #expect(rebuilt.recordID == record.recordID)
    }
}
