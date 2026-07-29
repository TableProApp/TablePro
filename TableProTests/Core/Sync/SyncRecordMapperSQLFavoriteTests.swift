import CloudKit
import Foundation
@testable import TablePro
import Testing

@Suite("SyncRecordMapper SQL favorites")
struct SyncRecordMapperSQLFavoriteTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
    private let created = Date(timeIntervalSince1970: 1_000)
    private let updated = Date(timeIntervalSince1970: 2_000)

    @Test("SQL favorite record round trips all fields")
    func sqlFavoriteRoundTrip() throws {
        let favorite = SQLFavorite(
            id: UUID(),
            name: "Active users",
            query: "SELECT * FROM users WHERE active = true",
            keyword: "au",
            folderId: UUID(),
            connectionId: UUID(),
            sortOrder: 3,
            createdAt: created,
            updatedAt: updated
        )

        let record = SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: zoneID)
        #expect(record.recordType == SyncRecordType.favorite.rawValue)
        #expect(record.recordID.recordName == "Favorite_\(favorite.id.uuidString)")
        #expect(record["query"] as? String == favorite.query)
        #expect(record["keyword"] as? String == "au")
        #expect(record["sortOrder"] as? Int64 == 3)

        let decoded = try SyncRecordMapper.sqlFavorite(from: record)
        #expect(decoded == favorite)
    }

    @Test("SQL favorite without optional fields round trips")
    func sqlFavoriteMinimalRoundTrip() throws {
        let favorite = SQLFavorite(
            id: UUID(),
            name: "All orders",
            query: "SELECT * FROM orders",
            keyword: nil,
            folderId: nil,
            connectionId: nil,
            sortOrder: 0,
            createdAt: created,
            updatedAt: updated
        )

        let record = SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: zoneID)
        #expect(record["keyword"] == nil)
        #expect(record["folderId"] == nil)
        #expect(record["connectionId"] == nil)

        let decoded = try SyncRecordMapper.sqlFavorite(from: record)
        #expect(decoded == favorite)
    }

    @Test("Decoding a SQL favorite without a required field throws")
    func sqlFavoriteMissingFieldThrows() {
        let record = CKRecord(recordType: SyncRecordType.favorite.rawValue)
        #expect(throws: SyncDecodeError.self) {
            _ = try SyncRecordMapper.sqlFavorite(from: record)
        }
    }

    @Test("SQL favorite folder round trips all fields")
    func sqlFolderRoundTrip() throws {
        let folder = SQLFavoriteFolder(
            id: UUID(),
            name: "Reports",
            parentId: UUID(),
            connectionId: UUID(),
            sortOrder: 5,
            createdAt: created,
            updatedAt: updated
        )

        let record = SyncRecordMapper.toCKRecord(sqlFavoriteFolder: folder, in: zoneID)
        #expect(record.recordType == SyncRecordType.favoriteFolder.rawValue)
        #expect(record.recordID.recordName == "FavoriteFolder_\(folder.id.uuidString)")

        let decoded = try SyncRecordMapper.sqlFavoriteFolder(from: record)
        #expect(decoded == folder)
    }

    @Test("SQL favorite folder without optional fields round trips")
    func sqlFolderMinimalRoundTrip() throws {
        let folder = SQLFavoriteFolder(
            id: UUID(),
            name: "Scratch",
            parentId: nil,
            connectionId: nil,
            sortOrder: 0,
            createdAt: created,
            updatedAt: updated
        )

        let record = SyncRecordMapper.toCKRecord(sqlFavoriteFolder: folder, in: zoneID)
        #expect(record["parentId"] == nil)
        #expect(record["connectionId"] == nil)

        let decoded = try SyncRecordMapper.sqlFavoriteFolder(from: record)
        #expect(decoded == folder)
    }
}
