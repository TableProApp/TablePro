import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct FavoriteTablesStorageTests {
    private static let storageKey = "com.TablePro.favoriteTables"

    private func makeFixture() throws -> (storage: FavoriteTablesStorage, defaults: UserDefaults, metadata: SyncMetadataStorage) {
        let favoritesSuite = "FavoriteTablesStorageTests.favorites.\(UUID().uuidString)"
        let syncSuite = "FavoriteTablesStorageTests.sync.\(UUID().uuidString)"
        let favoritesDefaults = try #require(UserDefaults(suiteName: favoritesSuite))
        let syncDefaults = try #require(UserDefaults(suiteName: syncSuite))
        favoritesDefaults.removePersistentDomain(forName: favoritesSuite)
        syncDefaults.removePersistentDomain(forName: syncSuite)

        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        let storage = FavoriteTablesStorage(userDefaults: favoritesDefaults, syncTracker: tracker)
        return (storage, favoritesDefaults, metadata)
    }

    private func makeStorage() throws -> (FavoriteTablesStorage, SyncMetadataStorage) {
        let fixture = try makeFixture()
        return (fixture.storage, fixture.metadata)
    }

    private func countingChanges(of storage: FavoriteTablesStorage, during body: () -> Void) -> Int {
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .favoriteTablesDidChange, object: storage, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        body()
        return notifications
    }

    private func entry(
        _ name: String,
        database: String? = "shop",
        schema: String? = nil,
        connectionId: UUID
    ) -> FavoriteTablesStorage.FavoriteEntry {
        FavoriteTablesStorage.FavoriteEntry(connectionId: connectionId, database: database, schema: schema, name: name)
    }

    /// The only writer of a table favorite keys it on the table's own schema, so anything reading
    /// one back has to ask the same way. Asking with the outline row's schema instead missed the
    /// entry outright in a hierarchical tree, where the schema hangs on the node.
    @Test("A tree row spells its favorite's schema the way the writer does")
    func favoriteSchemaMatchesTheWriter() {
        let hierarchical = DatabaseTreeTableRef(
            database: "shop", schema: "public", table: TestFixtures.makeTableInfo(name: "orders")
        )
        #expect(hierarchical.favoriteSchema == nil)
        #expect(hierarchical.qualifyingSchema == "public")

        let flat = DatabaseTreeTableRef(
            database: "shop", schema: nil, table: TestFixtures.makeTableInfo(name: "orders", schema: "public")
        )
        #expect(flat.favoriteSchema == "public")
    }

    @Test("Dropping a schema removes only the favorites inside it")
    func removeFavoritesInSchema() throws {
        let (storage, _) = try makeStorage()
        let connId = UUID()
        storage.addFavorite(name: "orders", schema: "public", database: "shop", connectionId: connId)
        storage.addFavorite(name: "invoices", schema: "public", database: "shop", connectionId: connId)
        storage.addFavorite(name: "orders", schema: "billing", database: "shop", connectionId: connId)
        storage.addFavorite(name: "orders", schema: "public", database: "other", connectionId: connId)

        storage.removeFavorites(inDatabase: "shop", schema: "public", connectionId: connId)

        let remaining = storage.favorites(for: connId)
        #expect(remaining.map(\.name).sorted() == ["orders", "orders"])
        #expect(remaining.contains { $0.schema == "billing" })
        #expect(remaining.contains { $0.database == "other" })
    }

    @Test("Dropping a database removes every schema's favorites under it")
    func removeFavoritesInDatabase() throws {
        let (storage, _) = try makeStorage()
        let connId = UUID()
        storage.addFavorite(name: "orders", schema: "public", database: "shop", connectionId: connId)
        storage.addFavorite(name: "orders", schema: "billing", database: "shop", connectionId: connId)
        storage.addFavorite(name: "orders", schema: "public", database: "other", connectionId: connId)

        storage.removeFavorites(inDatabase: "shop", schema: nil, connectionId: connId)

        #expect(storage.favorites(for: connId).allSatisfy { $0.database == "other" })
    }

    @Test("Dropping a container leaves another connection's favorites alone")
    func removeFavoritesIsScopedToItsConnection() throws {
        let (storage, _) = try makeStorage()
        let connId = UUID()
        let other = UUID()
        storage.addFavorite(name: "orders", schema: "public", database: "shop", connectionId: connId)
        storage.addFavorite(name: "orders", schema: "public", database: "shop", connectionId: other)

        storage.removeFavorites(inDatabase: "shop", schema: nil, connectionId: connId)

        #expect(storage.favorites(for: connId).isEmpty)
        #expect(storage.favorites(for: other).count == 1)
    }

    @Test("Dropping a container tombstones each removed favorite so the deletion syncs")
    func removeFavoritesTombstonesEachEntry() throws {
        let (storage, metadata) = try makeStorage()
        let connId = UUID()
        storage.addFavorite(name: "orders", schema: "public", database: "shop", connectionId: connId)
        let entry = FavoriteTablesStorage.FavoriteEntry(
            connectionId: connId, database: "shop", schema: "public", name: "orders"
        )

        storage.removeFavorites(inDatabase: "shop", schema: nil, connectionId: connId)

        #expect(
            metadata.tombstones(for: .tableFavorite)
                .contains { $0.id == FavoriteTablesStorage.syncId(for: entry) }
        )
    }

    @Test("Add favorite marks stable sync ID dirty")
    func addMarksDirty() throws {
        let (storage, metadata) = try makeStorage()
        let connId = UUID()
        storage.addFavorite(name: "users", schema: nil, database: nil, connectionId: connId)

        let entry = FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: nil, schema: nil, name: "users")
        let id = FavoriteTablesStorage.syncId(for: entry)
        #expect(storage.loadFavorites() == [entry])
        #expect(metadata.dirtyIds(for: .tableFavorite) == [id])
    }

    @Test("Remove favorite creates sync tombstone")
    func removeCreatesTombstone() throws {
        let (storage, metadata) = try makeStorage()
        let connId = UUID()
        storage.addFavorite(name: "users", schema: nil, database: nil, connectionId: connId)
        storage.removeFavorite(name: "users", schema: nil, database: nil, connectionId: connId)

        let entry = FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: nil, schema: nil, name: "users")
        let id = FavoriteTablesStorage.syncId(for: entry)
        #expect(storage.loadFavorites().isEmpty)
        #expect(metadata.dirtyIds(for: .tableFavorite).isEmpty)
        #expect(metadata.tombstones(for: .tableFavorite).contains { $0.id == id })
    }

    @Test("Remote apply does not track local sync changes")
    func remoteApplyDoesNotTrackChanges() throws {
        let (storage, metadata) = try makeStorage()
        let connId = UUID()
        let entry = FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: nil, schema: nil, name: "orders")
        let id = FavoriteTablesStorage.syncId(for: entry)
        storage.applyRemote(saved: [entry], deletedIds: [])
        #expect(storage.loadFavorites() == [entry])

        storage.applyRemote(saved: [], deletedIds: [id])

        #expect(storage.loadFavorites().isEmpty)
        #expect(metadata.dirtyIds(for: .tableFavorite).isEmpty)
        #expect(metadata.tombstones(for: .tableFavorite).isEmpty)
    }

    @Test("Favorites scoped per connection: same name in different connections are distinct")
    func favoritesAreConnectionScoped() throws {
        let (storage, _) = try makeStorage()
        let connA = UUID()
        let connB = UUID()
        storage.addFavorite(name: "users", schema: nil, database: nil, connectionId: connA)
        storage.addFavorite(name: "users", schema: nil, database: nil, connectionId: connB)

        let favA = storage.favorites(for: connA)
        let favB = storage.favorites(for: connB)
        #expect(favA.count == 1)
        #expect(favB.count == 1)
        #expect(favA.first?.connectionId == connA)
        #expect(favB.first?.connectionId == connB)
        #expect(storage.loadFavorites().count == 2)
    }

    @Test("Schema-qualified and unqualified same-named tables are distinct")
    func schemaQualifiedIsDistinct() throws {
        let (storage, _) = try makeStorage()
        let connId = UUID()
        storage.addFavorite(name: "users", schema: "public", database: nil, connectionId: connId)
        storage.addFavorite(name: "users", schema: "app", database: nil, connectionId: connId)
        storage.addFavorite(name: "users", schema: nil, database: nil, connectionId: connId)

        #expect(storage.favorites(for: connId).count == 3)
    }

    @Test("Same name and schema in different databases are distinct")
    func favoritesAreDatabaseScoped() throws {
        let (storage, _) = try makeStorage()
        let connId = UUID()
        storage.addFavorite(name: "users", schema: "public", database: "db1", connectionId: connId)
        storage.addFavorite(name: "users", schema: "public", database: "db2", connectionId: connId)

        #expect(storage.favorites(for: connId).count == 2)
        #expect(storage.isFavorite(name: "users", schema: "public", database: "db1", connectionId: connId))
        #expect(storage.isFavorite(name: "users", schema: "public", database: "db2", connectionId: connId))
        #expect(!storage.isFavorite(name: "users", schema: "public", database: "db3", connectionId: connId))
    }

    @Test("Toggle on then off leaves no dirty entries")
    func toggleOnThenOffNoDirty() throws {
        let (storage, metadata) = try makeStorage()
        let connId = UUID()
        storage.toggle(name: "orders", schema: nil, database: nil, connectionId: connId)
        storage.toggle(name: "orders", schema: nil, database: nil, connectionId: connId)

        #expect(storage.favorites(for: connId).isEmpty)
        #expect(metadata.dirtyIds(for: .tableFavorite).isEmpty)
    }

    @Test("Moving a database's favorites to its new name writes one change for all of them")
    func retargetingManyFavoritesIsOneChange() throws {
        let (storage, metadata) = try makeStorage()
        let connId = UUID()
        let names = (0..<200).map { "table_\($0)" }
        for name in names {
            storage.addFavorite(name: name, schema: "public", database: "shop", connectionId: connId)
        }
        metadata.clearDirty(type: .tableFavorite)

        let notifications = countingChanges(of: storage) {
            storage.retarget(connectionId: connId) { favorite in
                entry(favorite.name, database: "shop_v2", schema: favorite.schema, connectionId: connId)
            }
        }

        let moved = Set(names.map { entry($0, database: "shop_v2", schema: "public", connectionId: connId) })
        let original = Set(names.map { entry($0, database: "shop", schema: "public", connectionId: connId) })
        #expect(notifications == 1)
        #expect(storage.favorites(for: connId) == moved)
        #expect(metadata.dirtyIds(for: .tableFavorite) == Set(moved.map(FavoriteTablesStorage.syncId(for:))))
        #expect(Set(metadata.tombstones(for: .tableFavorite).map(\.id)) == Set(original.map(FavoriteTablesStorage.syncId(for:))))
    }

    @Test("Moving one connection's favorites leaves another connection's alone")
    func retargetIsScopedToItsConnection() throws {
        let (storage, metadata) = try makeStorage()
        let connId = UUID()
        let other = UUID()
        storage.addFavorite(name: "orders", schema: nil, database: "shop", connectionId: connId)
        storage.addFavorite(name: "orders", schema: nil, database: "shop", connectionId: other)
        metadata.clearDirty(type: .tableFavorite)

        storage.retarget(connectionId: connId) { entry($0.name, database: "archive", connectionId: connId) }

        #expect(storage.favorites(for: other) == [entry("orders", connectionId: other)])
        #expect(storage.favorites(for: connId) == [entry("orders", database: "archive", connectionId: connId)])
        #expect(!metadata.tombstones(for: .tableFavorite).contains {
            $0.id == FavoriteTablesStorage.syncId(for: entry("orders", connectionId: other))
        })
    }

    @Test("Renaming a table and renaming it back leaves the original to save and the detour to delete")
    func renameRoundTripLeavesTheOriginalDirty() throws {
        let (storage, metadata) = try makeStorage()
        let connId = UUID()
        let original = entry("orders", connectionId: connId)
        let detour = entry("orders_old", connectionId: connId)
        storage.addFavorite(name: "orders", schema: nil, database: "shop", connectionId: connId)
        metadata.clearDirty(type: .tableFavorite)

        storage.retarget(connectionId: connId) { $0 == original ? detour : $0 }
        storage.retarget(connectionId: connId) { $0 == detour ? original : $0 }

        let originalId = FavoriteTablesStorage.syncId(for: original)
        let detourId = FavoriteTablesStorage.syncId(for: detour)
        #expect(storage.favorites(for: connId) == [original])
        #expect(metadata.dirtyIds(for: .tableFavorite) == [originalId])
        #expect(Set(metadata.tombstones(for: .tableFavorite).map(\.id)) == [originalId, detourId])
    }

    @Test("Moving a favorite onto one that already exists merges the two")
    func retargetOntoAnExistingFavoriteMerges() throws {
        let (storage, metadata) = try makeStorage()
        let connId = UUID()
        let source = entry("orders", connectionId: connId)
        let target = entry("orders_v2", connectionId: connId)
        storage.addFavorite(name: "orders", schema: nil, database: "shop", connectionId: connId)
        storage.addFavorite(name: "orders_v2", schema: nil, database: "shop", connectionId: connId)
        metadata.clearDirty(type: .tableFavorite)

        storage.retarget(connectionId: connId) { $0 == source ? target : $0 }

        #expect(storage.favorites(for: connId) == [target])
        #expect(metadata.dirtyIds(for: .tableFavorite).isEmpty)
        #expect(metadata.tombstones(for: .tableFavorite).map(\.id) == [FavoriteTablesStorage.syncId(for: source)])
    }

    @Test("A change that changes nothing writes nothing and posts nothing")
    func noOpChangesPostNothing() throws {
        let (storage, metadata) = try makeStorage()
        let connId = UUID()
        storage.addFavorite(name: "orders", schema: nil, database: "shop", connectionId: connId)
        metadata.clearDirty(type: .tableFavorite)

        let notifications = countingChanges(of: storage) {
            storage.removeFavorite(name: "missing", schema: nil, database: "shop", connectionId: connId)
            storage.retarget(connectionId: connId) { $0 }
            storage.removeFavorites(inDatabase: "other", schema: nil, connectionId: connId)
            #expect(!storage.addFavorite(name: "orders", schema: nil, database: "shop", connectionId: connId))
        }

        #expect(notifications == 0)
        #expect(metadata.dirtyIds(for: .tableFavorite).isEmpty)
        #expect(metadata.tombstones(for: .tableFavorite).isEmpty)
    }

    @Test("Dropping a schema posts one change for every favorite it held")
    func droppingAContainerIsOneChange() throws {
        let (storage, metadata) = try makeStorage()
        let connId = UUID()
        for name in ["orders", "invoices", "customers"] {
            storage.addFavorite(name: name, schema: "public", database: "shop", connectionId: connId)
        }

        let notifications = countingChanges(of: storage) {
            storage.removeFavorites(inDatabase: "shop", schema: "public", connectionId: connId)
        }

        #expect(notifications == 1)
        #expect(storage.favorites(for: connId).isEmpty)
        #expect(metadata.tombstones(for: .tableFavorite).count == 3)
    }

    @Test("Dropping a database named by an empty string removes the favorites stored without one")
    func droppingAnEmptyDatabaseNameMatchesFavoritesWithoutOne() throws {
        let (storage, _) = try makeStorage()
        let connId = UUID()
        storage.addFavorite(name: "orders", schema: nil, database: nil, connectionId: connId)
        storage.addFavorite(name: "orders", schema: nil, database: "shop", connectionId: connId)

        storage.removeFavorites(inDatabase: "", schema: nil, connectionId: connId)

        #expect(storage.favorites(for: connId) == [entry("orders", connectionId: connId)])
    }

    @Test("An empty database or schema is the same favorite as none")
    func emptyContainersAreNone() {
        let connId = UUID()
        let empty = FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: "", schema: "", name: "orders")
        let none = FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: nil, schema: nil, name: "orders")

        #expect(empty == none)
        #expect(empty.database == nil)
        #expect(empty.schema == nil)
        #expect(FavoriteTablesStorage.syncId(for: empty) == FavoriteTablesStorage.syncId(for: none))
    }

    @Test("Stored favorites with empty containers load as none, and duplicates merge into one stored entry")
    func storedEmptyContainersMergeOnLoad() throws {
        let (storage, defaults, _) = try makeFixture()
        let connId = UUID().uuidString
        let json = """
            [{"connectionId":"\(connId)","database":"","schema":"","name":"orders"},
             {"connectionId":"\(connId)","name":"orders"}]
            """
        defaults.set(Data(json.utf8), forKey: Self.storageKey)

        let loaded = storage.loadFavorites()

        #expect(loaded.count == 1)
        #expect(loaded.first?.database == nil)
        #expect(loaded.first?.schema == nil)
        let stored = try JSONDecoder().decode(
            [FavoriteTablesStorage.FavoriteEntry].self,
            from: try #require(defaults.data(forKey: Self.storageKey))
        )
        #expect(stored.count == 1)
    }

    @Test("Re-keying at launch marks only the favorites whose id changed, under both ids, and tombstones nothing")
    func migrationMarksOnlyChangedIds() throws {
        let (storage, defaults, metadata) = try makeFixture()
        let connId = UUID()
        let piped = entry("orders", schema: "a|b", connectionId: connId)
        let slashed = entry("back\\slash", connectionId: connId)
        let plain = entry("orders", schema: "public", connectionId: connId)
        defaults.set(try JSONEncoder().encode([piped, slashed, plain]), forKey: Self.storageKey)

        storage.migrateSyncIdentityIfNeeded()

        let expected = Set([piped, slashed].map(FavoriteTablesStorage.syncId(for:)))
            .union([piped, slashed].compactMap(FavoriteTablesStorage.legacyAlias(of:)))
        #expect(expected.count == 4)
        #expect(metadata.dirtyIds(for: .tableFavorite) == expected)
        #expect(metadata.tombstones(for: .tableFavorite).isEmpty)
        #expect(storage.favorites(for: connId) == [piped, slashed, plain])

        metadata.clearDirty(type: .tableFavorite)
        storage.migrateSyncIdentityIfNeeded()

        #expect(metadata.dirtyIds(for: .tableFavorite).isEmpty)
    }

    @Test("An old-build deletion that two re-keyed favorites could both answer to removes neither")
    func ambiguousLegacyDeletionRemovesNothing() throws {
        let (storage, defaults, metadata) = try makeFixture()
        let connId = UUID()
        let first = entry("t", database: "a|b", schema: "c", connectionId: connId)
        let second = entry("t", database: "a", schema: "b|c", connectionId: connId)
        let legacyId = try #require(FavoriteTablesStorage.legacyAlias(of: first))
        #expect(FavoriteTablesStorage.legacyAlias(of: second) == legacyId)
        defaults.set(try JSONEncoder().encode([first, second]), forKey: Self.storageKey)
        storage.migrateSyncIdentityIfNeeded()
        metadata.clearDirty(type: .tableFavorite)

        let retired = storage.applyRemote(saved: [], deletedIds: [legacyId])

        #expect(retired.isEmpty)
        #expect(storage.favorites(for: connId) == [first, second])
    }

    @Test("Removing one of two favorites that shared an old id keeps the old record for the other")
    func sharedLegacyIdOutlivesOneRemoval() throws {
        let (storage, defaults, metadata) = try makeFixture()
        let connId = UUID()
        let first = entry("t", database: "a|b", schema: "c", connectionId: connId)
        let second = entry("t", database: "a", schema: "b|c", connectionId: connId)
        defaults.set(try JSONEncoder().encode([first, second]), forKey: Self.storageKey)
        storage.migrateSyncIdentityIfNeeded()

        let sharedAlias = try #require(FavoriteTablesStorage.legacyAlias(of: first))

        storage.removeFavorite(name: "t", schema: "c", database: "a|b", connectionId: connId)
        #expect(metadata.tombstones(for: .tableFavorite).map(\.id) == [FavoriteTablesStorage.syncId(for: first)])

        storage.removeFavorite(name: "t", schema: "b|c", database: "a", connectionId: connId)
        #expect(
            Set(metadata.tombstones(for: .tableFavorite).map(\.id))
                == [FavoriteTablesStorage.syncId(for: first), FavoriteTablesStorage.syncId(for: second), sharedAlias]
        )
    }
}
