import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct FavoriteTablesStorageTests {
    private func makeStorage() throws -> (FavoriteTablesStorage, SyncMetadataStorage) {
        let favoritesSuite = "FavoriteTablesStorageTests.favorites.\(UUID().uuidString)"
        let syncSuite = "FavoriteTablesStorageTests.sync.\(UUID().uuidString)"
        let favoritesDefaults = try #require(UserDefaults(suiteName: favoritesSuite))
        let syncDefaults = try #require(UserDefaults(suiteName: syncSuite))
        favoritesDefaults.removePersistentDomain(forName: favoritesSuite)
        syncDefaults.removePersistentDomain(forName: syncSuite)

        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        let storage = FavoriteTablesStorage(userDefaults: favoritesDefaults, syncTracker: tracker)
        return (storage, metadata)
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

    @Test("Remote apply helpers do not track local sync changes")
    func withoutSyncDoesNotTrackChanges() throws {
        let (storage, metadata) = try makeStorage()
        let connId = UUID()
        let entry = FavoriteTablesStorage.FavoriteEntry(connectionId: connId, database: nil, schema: nil, name: "orders")
        storage.addFavoriteWithoutSync(entry)
        storage.removeFavoriteWithoutSync(entry)

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
}
