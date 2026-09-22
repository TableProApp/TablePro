import CloudKit
import Foundation
import Testing

@testable import TableProModels
@testable import TableProSync
@testable import TableProSyncTransport

@Suite("Field level merge")
struct FieldLevelMergeTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func makeConnection(name: String = "Production", port: Int = 5_432) -> DatabaseConnection {
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
        #expect(CKRecord.isEqualRecordValue(Int64(5_432) as CKRecordValue, Int64(5_432) as CKRecordValue))
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
        #expect(CKRecord.isEqualRecordValue(Int64(5_432) as CKRecordValue, Int64(6_543) as CKRecordValue) == false)
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

    @Test("A field with no value is left out of the push by default")
    func anAbsentValueIsNotNamedByDefault() {
        let record = CKRecord(
            recordType: "Connection",
            recordID: CKRecord.ID(recordName: "Connection_A", zoneID: zoneID)
        )

        record.fields(ConnectionSyncField.self)[.groupId] = nil

        #expect(record.changedKeys().contains("groupId") == false)
        #expect(record.allKeys().contains("groupId") == false)
    }

    /// Issue #3045. Under `.changedKeys` the server keeps any key the push does not name, so a
    /// mapper that builds the whole record from the local model has to name the empty ones too or
    /// a field the user cleared is never cleared anywhere else. Measured on the macOS 27 SDK:
    /// naming it puts it in `changedKeys()` and leaves it out of `allKeys()`.
    @Test("A field with no value is named when the record is the whole truth")
    func anAbsentValueIsNamedWhenClearing() {
        let record = CKRecord(
            recordType: "Connection",
            recordID: CKRecord.ID(recordName: "Connection_A", zoneID: zoneID)
        )

        record.fields(ConnectionSyncField.self, absentValues: .clear)[.groupId] = nil

        #expect(record.changedKeys().contains("groupId"))
        #expect(record.allKeys().contains("groupId") == false)
    }

    @Test("Clearing an absent value still writes the fields that hold one")
    func clearingAbsentValuesKeepsRealOnes() {
        let record = CKRecord(
            recordType: "Connection",
            recordID: CKRecord.ID(recordName: "Connection_A", zoneID: zoneID)
        )

        let fields = record.fields(ConnectionSyncField.self, absentValues: .clear)
        fields[.name] = "Production"
        fields[.groupId] = nil

        #expect(record["name"] as? String == "Production")
        #expect(record.allKeys().contains("name"))
    }

    /// The production-schema gate outranks the clear. A field that is not deployed must stay out of
    /// the push whichever answer the record wants for its empty fields, or naming it would have
    /// CloudKit reject the whole record.
    @Test("An unverified field is refused even when absent values are cleared")
    func anUnverifiedFieldIsStillRefused() {
        let record = CKRecord(
            recordType: "Probe",
            recordID: CKRecord.ID(recordName: "Probe_A", zoneID: zoneID)
        )

        let fields = record.fields(ProbeSyncField.self, absentValues: .clear)
        fields[.undeployed] = nil
        fields[.deployed] = nil

        #expect(record.changedKeys().contains("undeployed") == false)
        #expect(record.changedKeys().contains("deployed"))
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
        let suite = "com.TablePro.tests.\(UUID().uuidString)"
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

/// A schema with one deployed field and one that is not, so the gate can be tested against both
/// without waiting for a real type to be mid-deployment.
private enum ProbeSyncField: String, SyncSchemaField {
    case deployed
    case undeployed

    static let verifiedInProduction: Set<Self> = [.deployed]
}
