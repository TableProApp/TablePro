import CloudKit
import Foundation
import Testing

@testable import TableProModels
@testable import TableProSync
@testable import TableProSyncTransport

@Suite("Field level merge")
struct FieldLevelMergeTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func makeConnection(name: String = "Production", port: Int = 5432) -> DatabaseConnection {
        DatabaseConnection(
            id: UUID(),
            name: name,
            type: DatabaseType(rawValue: "PostgreSQL"),
            host: "db.example.com",
            port: port,
            username: "admin",
            database: "app",
            sortOrder: 1
        )
    }

    private func roundTripped(_ record: CKRecord) throws -> CKRecord {
        let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        return try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data))
    }

    @Test("Updating a cached server record keeps fields this platform never writes")
    func foreignFieldsSurviveAnUpdate() throws {
        var connection = makeConnection()
        let serverRecord = try roundTripped(SyncRecordMapper.toRecord(connection, zoneID: zoneID))
        serverRecord["aiPolicy"] = "askEachTime" as CKRecordValue
        serverRecord["startupCommands"] = "SET search_path TO public" as CKRecordValue

        connection.name = "Renamed"
        SyncRecordMapper.updateRecord(serverRecord, with: connection)

        #expect(serverRecord["aiPolicy"] as? String == "askEachTime")
        #expect(serverRecord["startupCommands"] as? String == "SET search_path TO public")
        #expect(serverRecord.fields(ConnectionSyncField.self)[.name] as? String == "Renamed")
    }

    @Test("An equal value is recognised so the field is left untouched")
    func equalValuesAreRecognised() {
        #expect(CKRecord.isEqualRecordValue("Production" as CKRecordValue, "Production" as CKRecordValue))
        #expect(CKRecord.isEqualRecordValue(Int64(5432) as CKRecordValue, Int64(5432) as CKRecordValue))
        #expect(CKRecord.isEqualRecordValue(nil, nil))
        #expect(CKRecord.isEqualRecordValue(
            ["a", "b"] as CKRecordValue,
            ["a", "b"] as CKRecordValue
        ))
        #expect(CKRecord.isEqualRecordValue(
            Data([1, 2, 3]) as CKRecordValue,
            Data([1, 2, 3]) as CKRecordValue
        ))
    }

    @Test("A differing value is recognised so the field is rewritten")
    func differingValuesAreRecognised() {
        #expect(CKRecord.isEqualRecordValue("Production" as CKRecordValue, "Staging" as CKRecordValue) == false)
        #expect(CKRecord.isEqualRecordValue(Int64(5432) as CKRecordValue, Int64(6543) as CKRecordValue) == false)
        #expect(CKRecord.isEqualRecordValue(nil, "Production" as CKRecordValue) == false)
        #expect(CKRecord.isEqualRecordValue("Production" as CKRecordValue, nil) == false)
        #expect(CKRecord.isEqualRecordValue(
            ["a", "b"] as CKRecordValue,
            ["a"] as CKRecordValue
        ) == false)
        #expect(CKRecord.isEqualRecordValue(
            Data([1, 2, 3]) as CKRecordValue,
            Data([1, 2]) as CKRecordValue
        ) == false)
    }

    @Test("Clearing a field that was already absent leaves it absent")
    func clearingAnAbsentFieldIsANoOp() throws {
        var connection = makeConnection()
        connection.groupId = nil
        let serverRecord = try roundTripped(SyncRecordMapper.toRecord(connection, zoneID: zoneID))

        SyncRecordMapper.updateRecord(serverRecord, with: connection)

        #expect(serverRecord.fields(ConnectionSyncField.self)[.groupId] == nil)
    }

    @Test("Clearing a field that had a value removes it")
    func clearingAPopulatedFieldRemovesIt() throws {
        var connection = makeConnection()
        connection.groupId = UUID()
        let serverRecord = try roundTripped(SyncRecordMapper.toRecord(connection, zoneID: zoneID))

        connection.groupId = nil
        SyncRecordMapper.updateRecord(serverRecord, with: connection)

        #expect(serverRecord.fields(ConnectionSyncField.self)[.groupId] == nil)
    }
}

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
        let suite = "com.TablePro.tests.\(UUID().uuidString)"
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

    @Test("An unknown record is absent")
    func unknownRecordIsAbsent() throws {
        let cache = try makeCache()

        #expect(cache.record(for: CKRecord.ID(recordName: "Connection_Z", zoneID: zoneID)) == nil)
    }
}
