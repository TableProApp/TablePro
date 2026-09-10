//
//  SyncRecordIdentityTests.swift
//  TableProTests
//

import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@Suite("Push identities survive a shortened record name")
@MainActor
struct SyncRecordIdentityTests {
    private static let zone = CKRecordZone.ID(zoneName: "TableProZone", ownerName: CKCurrentUserDefaultName)

    private static func longColumnLayoutCategory() -> String {
        let path = "/Users/example/projects/acme/api/.wrangler/state/v3/d1"
            + "/miniflare-D1DatabaseObject/" + String(repeating: "f", count: 64) + ".sqlite"
        let key = ColumnLayoutTableKey(
            connectionId: UUID(),
            databaseName: path,
            schemaName: nil,
            tableName: "d1_migrations"
        )
        return FileColumnLayoutPersister.syncCategory(for: key.storageKey)
    }

    @Test("A category too long for a record name still resolves back to itself")
    func longCategoryResolvesBack() {
        let category = Self.longColumnLayoutCategory()
        let identities = SyncRecordMapper.identities(for: [.settings: [category]], in: Self.zone)
        let recordID = SyncRecordMapper.recordID(type: .settings, id: category, in: Self.zone)

        #expect(identities[recordID] == SyncRecordIdentity(type: .settings, id: category))
    }

    /// The record name carries a digest once it is shortened, so the identifier the push needs
    /// back is not in it. Reading it out of the name clears the wrong dirty entry, which leaves
    /// the real one dirty and pushes the same record on every sync forever.
    @Test("The shortened record name no longer carries the category")
    func aShortenedNameDoesNotCarryTheCategory() {
        let category = Self.longColumnLayoutCategory()
        #expect((("Settings_" + category) as NSString).length > SyncRecordName.maximumLength, """
        The fixture no longer exceeds CloudKit's limit, so this check would pass vacuously.
        """)

        let recordID = SyncRecordMapper.recordID(type: .settings, id: category, in: Self.zone)
        let parsed = SyncRecordMapper.parse(recordName: recordID.recordName)

        #expect((recordID.recordName as NSString).length <= SyncRecordName.maximumLength)
        #expect(parsed?.type == .settings)
        #expect(parsed?.id != category)
    }

    @Test("A short identifier resolves back without being shortened")
    func shortIdentifierResolvesBack() {
        let id = UUID().uuidString
        let identities = SyncRecordMapper.identities(for: [.connection: [id]], in: Self.zone)
        let recordID = SyncRecordMapper.recordID(type: .connection, id: id, in: Self.zone)

        #expect(recordID.recordName == "Connection_" + id)
        #expect(identities[recordID] == SyncRecordIdentity(type: .connection, id: id))
    }

    @Test("Identities keep every type apart")
    func identitiesKeepTypesApart() {
        let id = UUID().uuidString
        let identities = SyncRecordMapper.identities(
            for: [.connection: [id], .group: [id], .tag: [id]],
            in: Self.zone
        )

        #expect(identities.count == 3)
        #expect(identities[SyncRecordMapper.recordID(type: .group, id: id, in: Self.zone)]?.type == .group)
    }
}
