import CloudKit
import Foundation
import Testing

@testable import TableProModels
@testable import TableProSync
@testable import TableProSyncTransport

struct SyncRecordMapperSavedQueryTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
    private let created = Date(timeIntervalSince1970: 1_000)
    private let updated = Date(timeIntervalSince1970: 2_000)

    private func filedQuery() -> SavedQuery {
        SavedQuery(
            name: "Daily users",
            query: "SELECT count(*) FROM users",
            keyword: "dau",
            folderId: UUID(),
            connectionId: UUID(),
            sortOrder: 4,
            createdAt: created,
            updatedAt: updated
        )
    }

    private func nestedFolder() -> SavedQueryFolder {
        SavedQueryFolder(
            name: "Reports",
            parentId: UUID(),
            connectionId: UUID(),
            sortOrder: 2,
            createdAt: created,
            updatedAt: updated
        )
    }

    private func rawRecord(_ type: SyncRecordType, values: [String: CKRecordValue]) -> CKRecord {
        let id = SyncRecordMapper.recordID(type: type, id: UUID().uuidString, in: zoneID)
        let record = CKRecord(recordType: type.rawValue, recordID: id)
        for (key, value) in values {
            record[key] = value
        }
        return record
    }

    @Test("A saved query survives a trip through a record")
    func queryRoundTrips() throws {
        let query = filedQuery()

        let decoded = try #require(SyncRecordMapper.toSavedQuery(SyncRecordMapper.toRecord(query, zoneID: zoneID)))

        #expect(decoded == query)
    }

    @Test("A saved query record carries the Mac's record type and name")
    func queryRecordIdentity() {
        let query = filedQuery()

        let record = SyncRecordMapper.toRecord(query, zoneID: zoneID)

        #expect(record.recordType == "SQLFavorite")
        #expect(record.recordID.recordName == "Favorite_\(query.id.uuidString)")
        #expect(Set(record.allKeys()).isSubset(of: SQLFavoriteSyncField.declaredKeys))
    }

    @Test("A global, unfiled query without a keyword names those keys so the server clears them")
    func globalUnfiledQueryClearsItsKeys() {
        let query = SavedQuery(name: "Everywhere", query: "SELECT 1", createdAt: created)

        let record = SyncRecordMapper.toRecord(query, zoneID: zoneID)

        for key in ["connectionId", "folderId", "keyword"] {
            #expect(record.changedKeys().contains(key))
            #expect(!record.allKeys().contains(key))
        }
    }

    @Test("A pulled query keeps the creation date the keyword contest is decided by")
    func createdAtIsKept() throws {
        let record = SyncRecordMapper.toRecord(filedQuery(), zoneID: zoneID)

        let decoded = try #require(SyncRecordMapper.toSavedQuery(record))

        #expect(decoded.createdAt == created)
        #expect(decoded.updatedAt == updated)
    }

    @Test("A record with only the required fields decodes with the defaults")
    func minimalQueryRecordDecodes() throws {
        let id = UUID()
        let record = rawRecord(.favorite, values: [
            "favoriteId": id.uuidString as CKRecordValue,
            "name": "Bare" as CKRecordValue,
            "query": "SELECT 1" as CKRecordValue
        ])

        let decoded = try #require(SyncRecordMapper.toSavedQuery(record))

        #expect(decoded.id == id)
        #expect(decoded.keyword == nil)
        #expect(decoded.folderId == nil)
        #expect(decoded.connectionId == nil)
        #expect(decoded.sortOrder == 0)
    }

    @Test("A query record missing a required field is not decoded", arguments: ["favoriteId", "name", "query"])
    func queryMissingRequiredFieldIsNil(_ missing: String) {
        var values: [String: CKRecordValue] = [
            "favoriteId": UUID().uuidString as CKRecordValue,
            "name": "Daily" as CKRecordValue,
            "query": "SELECT 1" as CKRecordValue
        ]
        values.removeValue(forKey: missing)

        #expect(SyncRecordMapper.toSavedQuery(rawRecord(.favorite, values: values)) == nil)
    }

    @Test("A query record whose id is not a UUID is not decoded")
    func queryWithBadIdIsNil() {
        let record = rawRecord(.favorite, values: [
            "favoriteId": "not-a-uuid" as CKRecordValue,
            "name": "Daily" as CKRecordValue,
            "query": "SELECT 1" as CKRecordValue
        ])

        #expect(SyncRecordMapper.toSavedQuery(record) == nil)
    }

    @Test("A saved query folder survives a trip through a record")
    func folderRoundTrips() throws {
        let folder = nestedFolder()

        let decoded = try #require(SyncRecordMapper.toSavedQueryFolder(SyncRecordMapper.toRecord(folder, zoneID: zoneID)))

        #expect(decoded == folder)
    }

    @Test("A folder record carries the Mac's record type and name")
    func folderRecordIdentity() {
        let folder = nestedFolder()

        let record = SyncRecordMapper.toRecord(folder, zoneID: zoneID)

        #expect(record.recordType == "SQLFavoriteFolder")
        #expect(record.recordID.recordName == "FavoriteFolder_\(folder.id.uuidString)")
        #expect(Set(record.allKeys()).isSubset(of: SQLFavoriteFolderSyncField.declaredKeys))
    }

    @Test("A global top-level folder names its parent and connection so the server clears them")
    func globalRootFolderClearsItsKeys() {
        let folder = SavedQueryFolder(name: "Shared", createdAt: created)

        let record = SyncRecordMapper.toRecord(folder, zoneID: zoneID)

        for key in ["connectionId", "parentId"] {
            #expect(record.changedKeys().contains(key))
            #expect(!record.allKeys().contains(key))
        }
    }

    @Test("A folder record missing a required field is not decoded", arguments: ["folderId", "name"])
    func folderMissingRequiredFieldIsNil(_ missing: String) {
        var values: [String: CKRecordValue] = [
            "folderId": UUID().uuidString as CKRecordValue,
            "name": "Reports" as CKRecordValue
        ]
        values.removeValue(forKey: missing)

        #expect(SyncRecordMapper.toSavedQueryFolder(rawRecord(.favoriteFolder, values: values)) == nil)
    }
}
