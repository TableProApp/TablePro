import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

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

    @Test("A favorite whose names hold no separator keeps the sync id every earlier build gave it")
    func plainNamesKeepTheirSyncId() throws {
        let entry = FavoriteTablesStorage.FavoriteEntry(
            connectionId: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            database: "shop",
            schema: "public",
            name: "users"
        )

        let expected = "d9ddf33921f51e2b0938b408b83e7de6f54d5338d28daba48a562f6ac74ba9d2"
        #expect(FavoriteTablesStorage.syncId(for: entry) == expected)
        #expect(FavoriteTablesStorage.legacyAlias(of: entry) == nil)
    }

    @Test("Favorites whose names differ only in where a vertical bar falls get their own records")
    func separatorInNamesKeepsIdsApart() {
        let connId = UUID()
        let pairs: [(FavoriteTablesStorage.FavoriteEntry, FavoriteTablesStorage.FavoriteEntry)] = [
            (
                FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: "a|b", schema: "c", name: "t"),
                FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: "a", schema: "b|c", name: "t")
            ),
            (
                FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: "a", schema: "b", name: "c|t"),
                FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: "a", schema: "b|c", name: "t")
            ),
            (
                FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: "a|", schema: nil, name: "b"),
                FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: "a", schema: nil, name: "|b")
            )
        ]

        for (first, second) in pairs {
            #expect(FavoriteTablesStorage.legacyAlias(of: first) != nil)
            #expect(FavoriteTablesStorage.legacyAlias(of: first) == FavoriteTablesStorage.legacyAlias(of: second))
            #expect(FavoriteTablesStorage.syncId(for: first) != FavoriteTablesStorage.syncId(for: second))
        }
    }

    @Test("A re-keyed favorite never lands on the record another favorite used before the re-key")
    func escapedIdsStayOutOfTheLegacyNamespace() {
        let connId = UUID()
        let piped = FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: "a|b", schema: "c", name: "t")
        let slashed = FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: "a\\", schema: "b", name: "c|t")
        let unseparated = IdentityPath.joined([connId.uuidString, "a|b", "c", "t"], separator: "|").sha256

        #expect(unseparated == FavoriteTablesStorage.legacyAlias(of: slashed))
        #expect(FavoriteTablesStorage.syncId(for: piped) != FavoriteTablesStorage.legacyAlias(of: slashed))
        #expect(FavoriteTablesStorage.syncId(for: slashed) != FavoriteTablesStorage.legacyAlias(of: piped))
    }

    @Test("A favorite with a vertical bar in its name round trips under its own record name")
    func separatorNameRoundTrips() throws {
        let entry = FavoriteTablesStorage.FavoriteEntry(
            connectionId: UUID(), database: "shop", schema: "a|b", name: "back\\slash"
        )
        let record = SyncRecordMapper.toCKRecord(favoriteEntry: entry, in: zoneID)

        #expect(record.recordID.recordName == "FavoriteTable_\(FavoriteTablesStorage.syncId(for: entry))")
        #expect(try SyncRecordMapper.favoriteEntry(from: record) == entry)
    }

    @Test("A record carrying an empty schema decodes as a favorite with none")
    func emptySchemaDecodesAsNone() throws {
        let connId = UUID()
        let record = SyncRecordMapper.toCKRecord(
            favoriteEntry: FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: "shop", schema: nil, name: "users"),
            in: zoneID
        )
        record["schema"] = ""

        let decoded = try SyncRecordMapper.favoriteEntry(from: record)

        #expect(decoded.schema == nil)
        #expect(decoded == FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: "shop", schema: nil, name: "users"))
    }
}
