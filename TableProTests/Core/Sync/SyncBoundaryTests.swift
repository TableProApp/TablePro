import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncBoundaryTests {
    private static let everyCategoryOn = SyncSettings(
        enabled: true,
        syncConnections: true,
        syncGroupsAndTags: true,
        syncSettings: true
    )

    private static func connection(localOnly: Bool = false, isSample: Bool = false) -> DatabaseConnection {
        var connection = TestFixtures.makeConnection()
        connection.localOnly = localOnly
        connection.isSample = isSample
        return connection
    }

    @Test("Every record type is in scope exactly when its category syncs and its type is deployed")
    func typeScopeFollowsCategoryAndDeployment() {
        var settings = Self.everyCategoryOn
        settings.syncTableFavorites = false
        let writable = SyncRecordType.verifiedInProduction.subtracting([.favoriteDatabase])

        let boundary = SyncBoundary(settings: settings, connections: [], writableTypes: writable)

        for type in SyncRecordType.allCases {
            let expected = settings.syncs(type) && writable.contains(type)
            #expect(boundary.includes(type) == expected, "\(type.rawValue)")
        }
        #expect(!boundary.includes(.tableFavorite))
        #expect(!boundary.includes(.favoriteDatabase))
        #expect(boundary.includes(.favorite))
    }

    @Test("Local only and sample connections are refused as owners, synced and unknown ones are not")
    func ownersKeptOffICloudAreRefused() {
        let localOnly = Self.connection(localOnly: true)
        let sample = Self.connection(isSample: true)
        let synced = Self.connection()
        let boundary = SyncBoundary(settings: Self.everyCategoryOn, connections: [localOnly, sample, synced])

        #expect(boundary.excludedConnectionIds == [localOnly.id, sample.id])
        #expect(!boundary.includes(.tableFavorite, owner: localOnly.id))
        #expect(!boundary.includes(.favorite, owner: sample.id))
        #expect(boundary.includes(.tableFavorite, owner: synced.id))
        #expect(boundary.includes(.favoriteDatabase, owner: UUID()))
        #expect(boundary.includes(.favorite, owner: nil))
    }

    @Test("A deleted connection still being purged stays refused, and a connection that exists again follows its own flag")
    func ownersKeptOffSyncApplyOnlyToDeletedConnections() {
        let deleted = UUID()
        let reimported = Self.connection()
        let boundary = SyncBoundary(
            settings: Self.everyCategoryOn,
            connections: [reimported],
            ownersKeptOffSync: [deleted, reimported.id]
        )

        #expect(!boundary.includes(.favorite, owner: deleted))
        #expect(boundary.includes(.favorite, owner: reimported.id))
    }

    @Test("An owner in scope is still refused when its record type is not")
    func ownerDoesNotOverrideCategory() {
        var settings = Self.everyCategoryOn
        settings.syncSQLFavorites = false
        let boundary = SyncBoundary(settings: settings, connections: [Self.connection()])

        #expect(!boundary.includes(.favorite, owner: nil))
        #expect(!boundary.includes(.favoriteFolder, owner: UUID()))
    }

    @Test("A connection store that cannot be read holds every owned record and lets unowned ones through")
    func unreadableStoreHoldsOwnedRecords() {
        let boundary = SyncBoundary(settings: Self.everyCategoryOn, connections: nil)

        #expect(!boundary.knowsOwners)
        #expect(!boundary.includes(.tableFavorite, owner: UUID()))
        #expect(boundary.includes(.favorite, owner: nil))
        #expect(boundary.includes(.tag))
    }

    @Test("A tombstone is held by the owner it was written with")
    func tombstoneHeldByItsOwner() {
        let localOnly = Self.connection(localOnly: true)
        let boundary = SyncBoundary(settings: Self.everyCategoryOn, connections: [localOnly])

        #expect(!boundary.includes(Tombstone(id: "a", owner: localOnly.id), of: .tableFavorite))
        #expect(boundary.includes(Tombstone(id: "b", owner: UUID()), of: .tableFavorite))
        #expect(boundary.includes(Tombstone(id: "c"), of: .tableFavorite))
    }

    @Test("A column layout tombstone written before owners existed is held by the connection its name carries")
    func legacyLayoutTombstoneOwnerComesFromItsName() {
        let localOnly = Self.connection(localOnly: true)
        let boundary = SyncBoundary(settings: Self.everyCategoryOn, connections: [localOnly])
        let key = ColumnLayoutTableKey(
            connectionId: localOnly.id, databaseName: "shop", schemaName: "public", tableName: "orders"
        )
        let category = FileColumnLayoutPersister.syncCategory(for: key.storageKey)

        #expect(SyncBoundary.owner(ofRecordId: category, type: .settings) == localOnly.id)
        #expect(SyncBoundary.owner(ofRecordId: AppSettingsCategory.editor, type: .settings) == nil)
        #expect(!boundary.includes(Tombstone(id: category), of: .settings))
    }
}
