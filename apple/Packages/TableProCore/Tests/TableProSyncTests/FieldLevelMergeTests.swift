import CloudKit
import Foundation
import Testing

@testable import TableProModels
@testable import TableProSyncTransport

@Suite("Sync record cache")
struct SyncRecordCacheTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    /// A throwaway directory per cache, because the cache is file-backed now: keeping it in
    /// UserDefaults put the whole com.TablePro domain over the 4 MB CFPreferences ceiling.
    private func makeCache() throws -> SyncRecordCache {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncRecordCacheTests/\(UUID().uuidString)", isDirectory: true)
        return SyncRecordCache(directory: directory, defaults: nil, storageKey: "recordCache")
    }

    private func makeRecord(_ name: String) -> CKRecord {
        let record = CKRecord(
            recordType: "Connection",
            recordID: CKRecord.ID(recordName: name, zoneID: zoneID)
        )
        record["name"] = "Production" as CKRecordValue
        return record
    }

    @Test("A stored record round-trips with its values")
    func storedRecordRoundTrips() throws {
        let cache = try makeCache()
        let record = makeRecord("Connection_A")

        cache.store([record])

        #expect(cache.record(for: record.recordID)?["name"] as? String == "Production")
    }

    @Test("Each read returns an independent copy so a failed push cannot poison the cache")
    func readsAreIndependent() throws {
        let cache = try makeCache()
        let record = makeRecord("Connection_A")
        cache.store([record])

        let first = try #require(cache.record(for: record.recordID))
        first["name"] = "Mutated" as CKRecordValue

        #expect(cache.record(for: record.recordID)?["name"] as? String == "Production")
    }

    @Test("Replacing the whole cache keeps exactly the records handed in, rewriting only what changed")
    func replaceAllKeepsOnlyTheRecordsHandedIn() throws {
        let cache = try makeCache()
        let kept = makeRecord("Connection_Kept")
        let dropped = makeRecord("Connection_Dropped")
        cache.store([kept, dropped])
        let edited = makeRecord("Connection_Kept")
        edited["name"] = "Staging" as CKRecordValue
        let added = makeRecord("Connection_Added")

        #expect(cache.replaceAll(with: [edited, added]))

        #expect(cache.record(named: "Connection_Kept")?["name"] as? String == "Staging")
        #expect(cache.record(named: "Connection_Added") != nil)
        #expect(cache.record(named: "Connection_Dropped") == nil)
        #expect(cache.allRecords().map(\.recordID.recordName).sorted() == ["Connection_Added", "Connection_Kept"])
    }

    @Test("A cache whose folder cannot be listed reports a replace as failed instead of empty")
    func replaceAllFailsWhenTheFolderCannotBeListed() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncRecordCacheTests/\(UUID().uuidString)", isDirectory: true)
        let cache = SyncRecordCache(directory: directory, defaults: nil, storageKey: "recordCache")
        cache.store([makeRecord("Connection_Old")])
        try FileManager.default.setAttributes([.posixPermissions: 0o333], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        #expect(!cache.replaceAll(with: []))
    }

    @Test("Replacing the cache with nothing empties it")
    func replaceAllWithNothingEmptiesIt() throws {
        let cache = try makeCache()
        cache.store([makeRecord("Connection_A")])

        #expect(cache.replaceAll(with: []))

        #expect(cache.allRecords().isEmpty)
    }

    @Test("A removed record is gone")
    func removedRecordIsGone() throws {
        let cache = try makeCache()
        let record = makeRecord("Connection_A")
        cache.store([record])

        cache.remove([record.recordID])

        #expect(cache.record(for: record.recordID) == nil)
    }

    /// The whole point of moving off UserDefaults: an existing cache has to come with, and the key
    /// has to go, or the domain stays over the CFPreferences limit and every write keeps failing.
    @Test("A cache written to UserDefaults by an older build moves to disk and frees the key")
    func legacyCacheMigratesOffUserDefaults() throws {
        let suite = ScratchDefaults.suiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let record = makeRecord("Connection_Legacy")
        let archived = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        defaults.set(["Connection_Legacy": archived], forKey: "recordCache")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncRecordCacheTests/\(UUID().uuidString)", isDirectory: true)
        let cache = SyncRecordCache(directory: directory, defaults: defaults, storageKey: "recordCache")

        let restored = cache.record(for: record.recordID)
        #expect(restored?["name"] as? String == "Production")
        #expect(defaults.object(forKey: "recordCache") == nil, "The oversized key must be released")
    }

    @Test("Every cached record reads back, a pre-file cache's included, for the core engine's import")
    func allRecordsReadsEveryRecord() throws {
        let suite = ScratchDefaults.suiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = makeRecord("Connection_Legacy")
        let archived = try NSKeyedArchiver.archivedData(withRootObject: legacy, requiringSecureCoding: true)
        defaults.set(["Connection_Legacy": archived], forKey: "recordCache")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncRecordCacheTests/\(UUID().uuidString)", isDirectory: true)
        let cache = SyncRecordCache(directory: directory, defaults: defaults, storageKey: "recordCache")
        #expect(cache.allRecords().map(\.recordID.recordName) == ["Connection_Legacy"])

        cache.store([makeRecord("Connection_A")])

        #expect(Set(cache.allRecords().map(\.recordID.recordName)) == ["Connection_Legacy", "Connection_A"])
    }

    @Test("An empty cache reads back no record")
    func allRecordsOfAnEmptyCache() throws {
        #expect(try makeCache().allRecords().isEmpty)
    }

    @Test("Removing everything forgets every record, and storing works again afterwards")
    func removeAllForgetsEveryRecord() throws {
        let cache = try makeCache()
        let first = makeRecord("Connection_A")
        let second = makeRecord("Connection_B")
        cache.store([first, second])

        cache.removeAll()

        #expect(cache.record(for: first.recordID) == nil)
        #expect(cache.record(for: second.recordID) == nil)
        cache.store([first])
        #expect(cache.record(for: first.recordID)?["name"] as? String == "Production")
    }

    @Test("Removing everything drops a legacy UserDefaults cache, and a later read never brings it back")
    func removeAllDropsLegacyCache() throws {
        let suite = ScratchDefaults.suiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = makeRecord("Connection_Legacy")
        let archived = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        defaults.set(["Connection_Legacy": archived], forKey: "recordCache")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncRecordCacheTests/\(UUID().uuidString)", isDirectory: true)
        let cache = SyncRecordCache(directory: directory, defaults: defaults, storageKey: "recordCache")

        cache.removeAll()

        #expect(defaults.object(forKey: "recordCache") == nil)
        #expect(cache.record(for: record.recordID) == nil)
    }

    @Test("An unknown record is absent")
    func unknownRecordIsAbsent() throws {
        let cache = try makeCache()

        #expect(cache.record(for: CKRecord.ID(recordName: "Connection_Z", zoneID: zoneID)) == nil)
    }
}
