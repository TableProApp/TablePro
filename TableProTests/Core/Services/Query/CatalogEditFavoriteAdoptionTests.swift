import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct CatalogEditFavoriteAdoptionTests {
    private let connection = TestFixtures.makeConnection(database: "shop")
    private let metadata: SyncMetadataStorage
    private let favoriteTables: FavoriteTablesStorage
    private let favoriteDatabases: FavoriteDatabasesStorage
    private let databaseManager: DatabaseManager
    private let adoption: CatalogEditAdoption

    init() throws {
        let unique = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.CatalogEditFavorites.\(unique)"))
        metadata = SyncMetadataStorage(
            userDefaults: try #require(UserDefaults(suiteName: "com.TablePro.tests.CatalogEditFavorites.sync.\(unique)"))
        )
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        favoriteTables = FavoriteTablesStorage(userDefaults: defaults, syncTracker: tracker)
        favoriteDatabases = FavoriteDatabasesStorage(defaults: defaults, syncTracker: tracker)
        let connectionStorage = ConnectionStorage(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tablepro-tests")
                .appendingPathComponent("catalog-edit-favorites-\(unique).json"),
            userDefaults: defaults,
            syncTracker: tracker,
            keychain: InMemoryKeychain()
        )
        databaseManager = DatabaseManager(connectionStorage: connectionStorage)
        adoption = CatalogEditAdoption(
            databaseManager: databaseManager,
            connectionStorage: connectionStorage,
            favoriteTables: favoriteTables,
            favoriteDatabases: favoriteDatabases
        )
    }

    private func withSession(_ body: () -> Void) {
        databaseManager.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer {
            databaseManager.removeSession(for: connection.id)
            SharedSidebarState.removeConnection(connection.id)
        }
        body()
    }

    private func changes(of name: Notification.Name, from sender: AnyObject, during body: () -> Void) -> Int {
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: name, object: sender, queue: nil) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        body()
        return notifications
    }

    @Test("Renaming a database moves every favorite table in it, and its own favorite, one change each")
    func databaseRenameMovesFavoritesInOneChange() {
        let names = (0..<200).map { "table_\($0)" }
        for name in names {
            favoriteTables.addFavorite(name: name, schema: "public", database: "shop", connectionId: connection.id)
        }
        favoriteTables.addFavorite(name: "orders", schema: "public", database: "archive", connectionId: connection.id)
        favoriteDatabases.setFavorite(database: "shop", environment: .production, connectionId: connection.id)
        metadata.clearDirty(type: .tableFavorite)
        metadata.clearDirty(type: .favoriteDatabase)

        var databaseChanges = 0
        let tableChanges = changes(of: .favoriteTablesDidChange, from: favoriteTables) {
            databaseChanges = changes(of: .favoriteDatabasesDidChange, from: favoriteDatabases) {
                withSession {
                    adoption.adoptContainerRename(.database("shop"), to: "shop_v2", connectionId: connection.id)
                }
            }
        }

        let favorites = favoriteTables.favorites(for: connection.id)
        #expect(tableChanges == 1)
        #expect(databaseChanges == 1)
        #expect(favorites.filter { $0.database == "shop_v2" }.count == 200)
        #expect(favorites.contains { $0.database == "archive" })
        #expect(!favorites.contains { $0.database == "shop" })
        #expect(metadata.dirtyIds(for: .tableFavorite).count == 200)
        #expect(metadata.tombstones(for: .tableFavorite).count == 200)
        #expect(favoriteDatabases.favorites(for: connection.id).map(\.database) == ["shop_v2"])
    }

    @Test("Renaming a table moves its star, spelled by the table's own schema")
    func tableRenameMovesTheStar() {
        let table = TestFixtures.makeTableInfo(name: "orders", schema: "public")
        let ref = DatabaseTreeTableRef(database: "shop", schema: nil, table: table)
        favoriteTables.addFavorite(name: "orders", schema: "public", database: "shop", connectionId: connection.id)

        let tableChanges = changes(of: .favoriteTablesDidChange, from: favoriteTables) {
            withSession {
                adoption.adoptTableRename(ref, to: "orders_v2", connectionId: connection.id)
            }
        }

        #expect(tableChanges == 1)
        #expect(favoriteTables.favorites(for: connection.id).map(\.name) == ["orders_v2"])
    }

    @Test("A star written from a table whose schema is empty follows its rename")
    func emptySchemaStarFollowsTheRename() {
        let table = TestFixtures.makeTableInfo(name: "orders", schema: "")
        let ref = DatabaseTreeTableRef(database: "shop", schema: nil, table: table)
        favoriteTables.addFavorite(name: "orders", schema: table.schema, database: "shop", connectionId: connection.id)

        withSession {
            adoption.adoptTableRename(ref, to: "orders_v2", connectionId: connection.id)
        }

        #expect(favoriteTables.favorites(for: connection.id).map(\.name) == ["orders_v2"])
    }
}
