import CloudKit
import Foundation
@testable import TablePro
import Testing

@Suite("SyncRecordMapper favorite tables")
struct SyncRecordMapperFavoriteTableTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    @Test("Table favorite record round trips all fields")
    func tableFavoriteRoundTrip() throws {
        let connId = UUID()
        let entry = FavoriteTablesStorage.FavoriteEntry(
            connectionId: connId, database: "shop", schema: "public", name: "users"
        )
        let record = SyncRecordMapper.toCKRecord(favoriteEntry: entry, in: zoneID)

        let id = FavoriteTablesStorage.syncId(for: entry)
        #expect(record.recordType == SyncRecordType.tableFavorite.rawValue)
        #expect(record.recordID.recordName == "FavoriteTable_\(id)")
        #expect(record["name"] as? String == "users")
        #expect(record["connectionId"] as? String == connId.uuidString)
        #expect(record["database"] as? String == "shop")
        #expect(record["schema"] as? String == "public")

        let decoded = try SyncRecordMapper.favoriteEntry(from: record)
        #expect(decoded == entry)
    }

    @Test("Table favorite without database or schema round trips correctly")
    func tableFavoriteNoDatabaseNoSchemaRoundTrip() throws {
        let connId = UUID()
        let entry = FavoriteTablesStorage.FavoriteEntry(
            connectionId: connId, database: nil, schema: nil, name: "orders"
        )
        let record = SyncRecordMapper.toCKRecord(favoriteEntry: entry, in: zoneID)

        #expect(record["database"] == nil)
        #expect(record["schema"] == nil)
        let decoded = try SyncRecordMapper.favoriteEntry(from: record)
        #expect(decoded == entry)
    }

    @Test("Same name and schema in different databases have distinct sync IDs")
    func distinctSyncIdsAcrossDatabases() {
        let connId = UUID()
        let entryA = FavoriteTablesStorage.FavoriteEntry(
            connectionId: connId, database: "db1", schema: "public", name: "users"
        )
        let entryB = FavoriteTablesStorage.FavoriteEntry(
            connectionId: connId, database: "db2", schema: "public", name: "users"
        )
        #expect(FavoriteTablesStorage.syncId(for: entryA) != FavoriteTablesStorage.syncId(for: entryB))
    }

    @Test("Two entries with same name but different connections have distinct sync IDs")
    func distinctSyncIds() {
        let connA = UUID()
        let connB = UUID()
        let entryA = FavoriteTablesStorage.FavoriteEntry(
            connectionId: connA, database: nil, schema: nil, name: "users"
        )
        let entryB = FavoriteTablesStorage.FavoriteEntry(
            connectionId: connB, database: nil, schema: nil, name: "users"
        )
        #expect(FavoriteTablesStorage.syncId(for: entryA) != FavoriteTablesStorage.syncId(for: entryB))
    }
}
