//
//  FavoriteDatabaseSyncTests.swift
//  TableProTests
//

import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@Suite("Favorite database sync")
struct FavoriteDatabaseSyncTests {
    private static let zoneID = CKRecordZone.ID(
        zoneName: "TableProSync",
        ownerName: CKCurrentUserDefaultName
    )

    /// `FavoriteDatabase` is declared but not deployed to the CloudKit Production schema, so every
    /// field is unverified and the gated subscript drops every write. That is what keeps the type
    /// inert: nothing reaches CloudKit until the schema ships and both sets flip together.
    @Test("The record type is deployed and every declared field is writable")
    func recordTypeIsWritable() {
        #expect(SyncRecordType.allCases.contains(.favoriteDatabase))
        #expect(SyncRecordType.favoriteDatabase.isWritable)
        #expect(FavoriteDatabaseSyncField.writableKeys == FavoriteDatabaseSyncField.declaredKeys)
        #expect(!FavoriteDatabaseSyncField.declaredKeys.isEmpty)
    }

    @Test("A record of the deployed type is published")
    func recordsArePublished() {
        let record = CKRecord(
            recordType: SyncRecordType.favoriteDatabase.rawValue,
            recordID: CKRecord.ID(
                recordName: SyncRecordType.favoriteDatabase.recordName(for: "abc"),
                zoneID: Self.zoneID
            )
        )

        #expect(SyncSchemaGate.publishable(records: [record]) == [record])
        #expect(SyncSchemaGate.withheldRecordTypes(in: [record]).isEmpty)
        #expect(SyncSchemaGate.publishable(deletions: [record.recordID]) == [record.recordID])
    }

    /// `FavoriteDatabase_` has to beat `Favorite_` when a record name is parsed back, which the
    /// longest-prefix ordering guarantees.
    @Test("A record name round trips to the right type")
    func recordNameRoundTrips() throws {
        let name = SyncRecordType.favoriteDatabase.recordName(for: "abc123")
        let parsed = try #require(SyncRecordType.parse(recordName: name))

        #expect(parsed.type == .favoriteDatabase)
        #expect(parsed.id == "abc123")
    }

    @Test("The type is in scope for sync rather than device-local")
    func syncScope() {
        #expect(SyncRecordType.favoriteDatabase.syncScope == .synced)
    }

    @Test("Every declared field carries a key")
    func declaredKeys() {
        #expect(
            FavoriteDatabaseSyncField.declaredKeys
                == ["connectionId", "database", "environment", "modifiedAtLocal", "schemaVersion"]
        )
    }

    /// The mapper's decode has to survive an environment a future build introduces, or one record
    /// from a newer device would drop the favorite instead of keeping it untagged.
    @Test("An unknown remote environment decodes as Unassigned")
    func unknownEnvironmentDecodes() throws {
        let record = CKRecord(
            recordType: SyncRecordType.favoriteDatabase.rawValue,
            recordID: CKRecord.ID(
                recordName: SyncRecordType.favoriteDatabase.recordName(for: "abc"),
                zoneID: Self.zoneID
            )
        )
        let connectionId = UUID()
        record["connectionId"] = connectionId.uuidString
        record["database"] = "app"
        record["environment"] = "staging"

        let entry = try SyncRecordMapper.favoriteDatabase(from: record)

        #expect(entry.connectionId == connectionId)
        #expect(entry.database == "app")
        #expect(entry.environment == .unassigned)
    }

    @Test("A record with no database is refused rather than decoded to an empty favorite")
    func missingDatabaseThrows() {
        let record = CKRecord(
            recordType: SyncRecordType.favoriteDatabase.rawValue,
            recordID: CKRecord.ID(
                recordName: SyncRecordType.favoriteDatabase.recordName(for: "abc"),
                zoneID: Self.zoneID
            )
        )
        record["connectionId"] = UUID().uuidString

        #expect(throws: (any Error).self) {
            try SyncRecordMapper.favoriteDatabase(from: record)
        }
    }

    /// Encoding writes through the gated subscript, which now passes every field of this type.
    @Test("Encoding produces the right record identity and writes its fields")
    func encodeWritesFields() {
        let entry = FavoriteDatabaseEntry(
            connectionId: UUID(),
            database: "app",
            environment: .production
        )
        let record = SyncRecordMapper.toCKRecord(favoriteDatabase: entry, in: Self.zoneID)

        #expect(record.recordType == "FavoriteDatabase")
        #expect(
            record.recordID.recordName
                == SyncRecordType.favoriteDatabase.recordName(for: FavoriteDatabasesStorage.syncId(for: entry))
        )
        #expect(record["database"] as? String == "app")
        #expect(record["environment"] as? String == FavoriteDatabaseEnvironment.production.rawValue)
    }
}
