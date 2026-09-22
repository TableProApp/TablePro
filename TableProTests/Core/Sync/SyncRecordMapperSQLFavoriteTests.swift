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
    /// record never names keeps whatever the server holds. Marking a query Global clears its
    /// connection id locally, and a mapper that wrote a field only when it was set said nothing
    /// about the key at all: the server kept the old connection and the next pull put it back.
    ///
    /// Measured on the macOS 27 SDK: assigning nil to a key a fresh `CKRecord` never held puts that
    /// key in `changedKeys()` and leaves it out of `allKeys()`, which is exactly the push that
    /// clears it. No record from the server is needed for that, and using one would restate every
    /// other field too, because an unarchived `CKRecord` reports all of its keys as changed.
    @Test("Making a query global names the connection id so the push clears it")
    func clearingAConnectionIdNamesTheKey() {
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

        let record = SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: zoneID)

        #expect(record["connectionId"] == nil)
        #expect(record["folderId"] == nil)
        #expect(record["keyword"] == nil)
        #expect(Set(record.changedKeys()).isSuperset(of: ["connectionId", "folderId", "keyword"]))
        #expect(Set(record.allKeys()).isDisjoint(with: ["connectionId", "folderId", "keyword"]))
    }

    @Test("Making a folder global names the connection id so the push clears it")
    func clearingAFolderConnectionIdNamesTheKey() {
        let folder = SQLFavoriteFolder(
            id: UUID(),
            name: "Reports",
            parentId: nil,
            connectionId: nil,
            sortOrder: 0,
            createdAt: created,
            updatedAt: updated
        )

        let record = SyncRecordMapper.toCKRecord(sqlFavoriteFolder: folder, in: zoneID)

        #expect(record["connectionId"] == nil)
        #expect(record["parentId"] == nil)
        #expect(Set(record.changedKeys()).isSuperset(of: ["connectionId", "parentId"]))
        #expect(Set(record.allKeys()).isDisjoint(with: ["connectionId", "parentId"]))
    }

    /// A field that does hold something is still written, so clearing the absent ones never costs
    /// the record its values.
    @Test("A query that is still scoped keeps its connection id on the record")
    func aScopedQueryKeepsItsConnectionId() {
        let connectionId = UUID()
        let folderId = UUID()
        let favorite = SQLFavorite(
            id: UUID(),
            name: "All orders",
            query: "SELECT * FROM orders",
            keyword: "ao",
            folderId: folderId,
            connectionId: connectionId,
            sortOrder: 0,
            createdAt: created,
            updatedAt: updated
        )

        let record = SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: zoneID)

        #expect(record["connectionId"] as? String == connectionId.uuidString)
        #expect(record["folderId"] as? String == folderId.uuidString)
        #expect(record["keyword"] as? String == "ao")
    }
}
