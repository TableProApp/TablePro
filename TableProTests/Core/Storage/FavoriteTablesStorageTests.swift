import Foundation
@testable import TablePro
import Testing

@Suite("FavoriteTablesStorage")
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
