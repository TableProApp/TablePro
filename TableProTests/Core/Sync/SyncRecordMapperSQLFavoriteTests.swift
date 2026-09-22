import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
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

    // MARK: - Emptying a field

    /// Issue #3045. `CKModifyRecordsOperation.savePolicy` is `.changedKeys`, so a key the pushed
    /// record does not carry keeps whatever the server holds. Marking a query Global clears its
    /// connection id locally, and without the record the server last gave us there is nothing for
    /// that clear to be written over: the key stays absent, the server keeps the old connection,
    /// and the next pull puts it back.
    @Test("Making a query global clears the connection id on the record the server holds")
    func clearingAConnectionIdOverABaseRecord() {
        let favorite = SQLFavorite(
            id: UUID(),
            name: "Truncate staging",
            query: "TRUNCATE TABLE staging;",
            keyword: nil,
            folderId: nil,
            connectionId: nil,
            sortOrder: 0,
            createdAt: created,
            updatedAt: updated
        )
        let base = SyncRecordMapper.toCKRecord(
            sqlFavorite: SQLFavorite(
                id: favorite.id,
                name: favorite.name,
                query: favorite.query,
                keyword: "ts",
                folderId: UUID(),
                connectionId: UUID(),
                sortOrder: 0,
                createdAt: created,
                updatedAt: updated
            ),
            in: zoneID
        )

        let record = SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: zoneID, base: base)

        #expect(record === base)
        #expect(record["connectionId"] == nil)
        #expect(record["folderId"] == nil)
        #expect(record["keyword"] == nil)
        #expect(Set(record.changedKeys()).isSuperset(of: ["connectionId", "folderId", "keyword"]))
    }

    @Test("Making a folder global clears the connection id on the record the server holds")
    func clearingAFolderConnectionIdOverABaseRecord() {
        let folder = SQLFavoriteFolder(
            id: UUID(),
            name: "Reports",
            parentId: nil,
            connectionId: nil,
            sortOrder: 0,
            createdAt: created,
            updatedAt: updated
        )
        let base = SyncRecordMapper.toCKRecord(
            sqlFavoriteFolder: SQLFavoriteFolder(
                id: folder.id,
                name: folder.name,
                parentId: UUID(),
                connectionId: UUID(),
                sortOrder: 0,
                createdAt: created,
                updatedAt: updated
            ),
            in: zoneID
        )

        let record = SyncRecordMapper.toCKRecord(sqlFavoriteFolder: folder, in: zoneID, base: base)

        #expect(record["connectionId"] == nil)
        #expect(record["parentId"] == nil)
        #expect(Set(record.changedKeys()).isSuperset(of: ["connectionId", "parentId"]))
    }

    /// A base belonging to another record cannot be written over, or one favorite's push would
    /// carry another's fields.
    @Test("A base for a different record is not adopted")
    func aMismatchedBaseIsIgnored() {
        let favorite = SQLFavorite(
            id: UUID(),
            name: "All orders",
            query: "SELECT * FROM orders",
            createdAt: created,
            updatedAt: updated
        )
        let stranger = CKRecord(
            recordType: SyncRecordType.favorite.rawValue,
            recordID: SyncRecordMapper.recordID(type: .favorite, id: UUID().uuidString, in: zoneID)
        )

        let record = SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: zoneID, base: stranger)

        #expect(record !== stranger)
        #expect(record.recordID.recordName == "Favorite_\(favorite.id.uuidString)")
    }
}
