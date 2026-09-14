import CloudKit
import Foundation
import Testing

@testable import TableProModels
@testable import TableProSync
@testable import TableProSyncTransport

@Suite("Favorite connections on iPhone")
struct SyncRecordMapperFavoriteTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func connection(isFavorite: Bool) -> DatabaseConnection {
        DatabaseConnection(name: "Prod", type: .postgresql, host: "db.example.com", port: 5_432, isFavorite: isFavorite)
    }

    @Test("A new record carries the favorite")
    func toRecordCarriesFavorite() throws {
        let record = SyncRecordMapper.toRecord(connection(isFavorite: true), zoneID: zoneID)
        let decoded = try #require(SyncRecordMapper.toConnection(record))
        #expect(decoded.isFavorite)
    }

    @Test("Updating a record clears or sets the favorite")
    func updateRecordCarriesFavorite() throws {
        let record = SyncRecordMapper.toRecord(connection(isFavorite: true), zoneID: zoneID)
        SyncRecordMapper.updateRecord(record, with: connection(isFavorite: false))
        let decoded = try #require(SyncRecordMapper.toConnection(record))
        #expect(!decoded.isFavorite)
    }

    @Test("A record written before favorites synced reads as not a favorite")
    func legacyRecordIsNotFavorite() throws {
        let id = SyncRecordMapper.recordID(type: .connection, id: UUID().uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.connection.rawValue, recordID: id)
        record["connectionId"] = UUID().uuidString as CKRecordValue
        record["name"] = "Legacy" as CKRecordValue
        record["type"] = DatabaseType.mysql.rawValue as CKRecordValue
        let decoded = try #require(SyncRecordMapper.toConnection(record))
        #expect(!decoded.isFavorite)
    }

    @Test("A connection saved on the device before favorites existed decodes as not a favorite")
    func legacyJSONIsNotFavorite() throws {
        let saved = connection(isFavorite: true)
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]
        )
        object.removeValue(forKey: "isFavorite")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: legacy)

        #expect(!decoded.isFavorite)
        #expect(try JSONDecoder().decode(DatabaseConnection.self, from: JSONEncoder().encode(saved)).isFavorite)
    }
}
