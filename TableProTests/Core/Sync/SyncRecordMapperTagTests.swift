import CloudKit
import Foundation
@testable import TablePro
import Testing

@Suite("SyncRecordMapper connection tags")
struct SyncRecordMapperTagTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    @Test("Writes every tag to tagIds and keeps legacy tagId for older clients")
    func writesEveryTagAndKeepsLegacyTagId() throws {
        let a = UUID()
        let b = UUID()
        var connection = DatabaseConnection(name: "Local")
        connection.tagIds = [a, b]

        let record = SyncRecordMapper.toCKRecord(connection, in: zoneID)

        #expect(record["tagId"] as? String == a.uuidString)
        #expect(record["tagIds"] as? [String] == [a.uuidString, b.uuidString])
        #expect(try SyncRecordMapper.toConnection(record).tagIds == [a, b])
    }

    @Test("Prefers tagIds array when a record carries one")
    func prefersTagIds() throws {
        let a = UUID()
        let b = UUID()
        var connection = DatabaseConnection(name: "Local")
        connection.tagIds = [a, b]
        let record = SyncRecordMapper.toCKRecord(connection, in: zoneID)
        record["tagIds"] = [a.uuidString, b.uuidString] as CKRecordValue

        let decoded = try SyncRecordMapper.toConnection(record)
        #expect(decoded.tagIds == [a, b])
    }

    @Test("Falls back to legacy tagId when tagIds absent")
    func fallsBackToTagId() throws {
        let legacy = UUID()
        var connection = DatabaseConnection(name: "Local")
        connection.tagIds = [legacy]
        let record = SyncRecordMapper.toCKRecord(connection, in: zoneID)
        record["tagIds"] = nil

        let decoded = try SyncRecordMapper.toConnection(record)
        #expect(decoded.tagIds == [legacy])
    }

    @Test("No tag fields decodes to empty array")
    func emptyTags() throws {
        let connection = DatabaseConnection(name: "Local")
        let record = SyncRecordMapper.toCKRecord(connection, in: zoneID)

        let decoded = try SyncRecordMapper.toConnection(record)
        #expect(decoded.tagIds.isEmpty)
    }
}
