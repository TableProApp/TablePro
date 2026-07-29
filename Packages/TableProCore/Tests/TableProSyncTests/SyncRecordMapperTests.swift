import CloudKit
import Foundation
import Testing

@testable import TableProModels
@testable import TableProSync

@Suite("SyncRecordMapper safe mode")
struct SyncRecordMapperTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func makeConnection(safeModeLevel: SafeModeLevel, isReadOnly: Bool = false) -> DatabaseConnection {
        DatabaseConnection(
            name: "Test",
            type: .postgresql,
            host: "db.example.com",
            port: 5432,
            username: "admin",
            database: "app",
            isReadOnly: isReadOnly,
            safeModeLevel: safeModeLevel
        )
    }

    private func makeRawRecord(safeModeLevelRaw: String?, isReadOnly: Bool? = nil) -> CKRecord {
        let id = SyncRecordMapper.recordID(type: .connection, id: UUID().uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.connection.rawValue, recordID: id)
        record["connectionId"] = UUID().uuidString as CKRecordValue
        record["name"] = "Test" as CKRecordValue
        record["type"] = DatabaseType.postgresql.rawValue as CKRecordValue
        if let safeModeLevelRaw {
            record["safeModeLevel"] = safeModeLevelRaw as CKRecordValue
        }
        if let isReadOnly {
            record["isReadOnly"] = Int64(isReadOnly ? 1 : 0) as CKRecordValue
        }
        return record
    }

    @Test("toRecord then toConnection preserves every safe mode level", arguments: SafeModeLevel.allCases)
    func roundTripsEachLevel(_ level: SafeModeLevel) throws {
        let record = SyncRecordMapper.toRecord(makeConnection(safeModeLevel: level), zoneID: zoneID)
        let decoded = try #require(SyncRecordMapper.toConnection(record))
        #expect(decoded.safeModeLevel == level)
    }

    @Test("updateRecord carries the new safe mode level")
    func updateRecordPreservesLevel() throws {
        let record = SyncRecordMapper.toRecord(makeConnection(safeModeLevel: .off), zoneID: zoneID)
        SyncRecordMapper.updateRecord(record, with: makeConnection(safeModeLevel: .confirmWrites))
        let decoded = try #require(SyncRecordMapper.toConnection(record))
        #expect(decoded.safeModeLevel == .confirmWrites)
    }

    @Test("legacy record without safeModeLevel falls back to isReadOnly")
    func legacyFallback() throws {
        let readOnlyRecord = makeRawRecord(safeModeLevelRaw: nil, isReadOnly: true)
        let readOnly = try #require(SyncRecordMapper.toConnection(readOnlyRecord))
        #expect(readOnly.safeModeLevel == .readOnly)

        let writableRecord = makeRawRecord(safeModeLevelRaw: nil, isReadOnly: false)
        let writable = try #require(SyncRecordMapper.toConnection(writableRecord))
        #expect(writable.safeModeLevel == .off)
    }

    @Test(
        "macOS wire values map to the nearest iOS level",
        arguments: [
            ("silent", SafeModeLevel.off),
            ("alert", SafeModeLevel.confirmWrites),
            ("alertFull", SafeModeLevel.confirmWrites),
            ("safeMode", SafeModeLevel.confirmWrites),
            ("safeModeFull", SafeModeLevel.confirmWrites),
            ("readOnly", SafeModeLevel.readOnly)
        ]
    )
    func decodesMacOSWireValues(_ raw: String, _ expected: SafeModeLevel) throws {
        let decoded = try #require(SyncRecordMapper.toConnection(makeRawRecord(safeModeLevelRaw: raw)))
        #expect(decoded.safeModeLevel == expected)
    }
}
