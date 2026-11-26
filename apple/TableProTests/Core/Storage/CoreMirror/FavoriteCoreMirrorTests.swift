import Foundation
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import Testing

@MainActor
struct FavoriteCoreMirrorTests {
    private let fixture: CoreMirrorFixture
    private let connectionId = UUID()

    init() throws {
        fixture = try CoreMirrorFixture()
    }

    private func tracker() throws -> SyncChangeTracker {
        SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: try fixture.pool.make().defaults))
    }

    private func favoriteTables(_ defaults: UserDefaults) throws -> FavoriteTablesStorage {
        FavoriteTablesStorage(userDefaults: defaults, syncTracker: try tracker(), core: fixture.core)
    }

    @Test("Favourite tables move in, and a toggle and the previous stable's removal reach the core")
    func favoriteTablesReachTheCore() async throws {
        let defaults = try fixture.pool.make().defaults
        let store = try favoriteTables(defaults)
        store.addFavorite(name: "orders", schema: "public", database: "shop", connectionId: connectionId)
        store.addFavorite(name: "users", schema: nil, database: "shop", connectionId: connectionId)
        let mirror = try #require(store.coreMirror)
        await mirror.push()

        var tables = try await fixture.core.favourites().contents().tables
        let names = tables.map { $0.name }.sorted()
        #expect(names == ["orders", "users"])
        #expect(tables.first { $0.name == "orders" }?.schema == "public")

        // The previous stable writes the defaults alone; this build's next launch reads them.
        let kept = store.loadFavorites().filter { $0.name != "users" }
        defaults.set(try JSONEncoder().encode(Array(kept)), forKey: "com.TablePro.favoriteTables")
        let relaunched = try favoriteTables(defaults)
        await relaunched.coreMirror?.push()

        tables = try await fixture.core.favourites().contents().tables
        #expect(tables.map { $0.name } == ["orders"])
    }

    @Test("Favourites that no longer decode take nothing out of the core")
    func unreadableFavoritesKeepTheCoreCopy() async throws {
        let defaults = try fixture.pool.make().defaults
        let store = try favoriteTables(defaults)
        store.addFavorite(name: "orders", schema: nil, database: "shop", connectionId: connectionId)
        await store.coreMirror?.push()
        defaults.set(Data("not json".utf8), forKey: "com.TablePro.favoriteTables")

        let relaunched = try favoriteTables(defaults)
        await relaunched.coreMirror?.push()

        let tables = try await fixture.core.favourites().contents().tables
        #expect(tables.map { $0.name } == ["orders"])
    }

    @Test("Favourite databases move in with their environment and leave the tables alone")
    func favoriteDatabasesReachTheCore() async throws {
        let tables = try favoriteTables(try fixture.pool.make().defaults)
        tables.addFavorite(name: "orders", schema: nil, database: "shop", connectionId: connectionId)
        await tables.coreMirror?.push()
        let store = FavoriteDatabasesStorage(
            defaults: try fixture.pool.make().defaults,
            syncTracker: try tracker(),
            core: fixture.core
        )
        store.setFavorite(database: "shop", environment: .production, connectionId: connectionId)
        store.setFavorite(database: "audit", environment: .testing, connectionId: connectionId)
        await store.coreMirror?.push()

        store.removeFavorite(database: "audit", connectionId: connectionId)
        await store.coreMirror?.push()

        let contents = try await fixture.core.favourites().contents()
        #expect(contents.databases.map { $0.database } == ["shop"])
        #expect(contents.databases.first?.environment == .production)
        #expect(contents.tables.map { $0.name } == ["orders"])
    }

    @Test("Table folders move in with their ids and times, and a folder deleted here leaves the core with its items")
    func tableFoldersReachTheCore() async throws {
        let store = TableFolderStorage(
            defaults: try fixture.pool.make().defaults,
            syncTracker: try tracker(),
            core: fixture.core,
            mirrorDefaults: try fixture.pool.make().defaults
        )
        let scope = DatabaseScope(connectionId: connectionId, database: "shop", schema: nil)
        let folder = store.createFolder(named: "Billing", in: scope, containing: ["invoices"])
        let mirror = try #require(store.coreMirror)
        await mirror.push()

        var contents = try await fixture.core.tableFolders().contents()
        let held = try #require(contents.folders.first)
        #expect(UUID(uuidString: held.id) == folder.id)
        #expect(held.createdAtMs == CoreMirrorTime.milliseconds(folder.createdAt))
        #expect(held.schema.isEmpty)
        #expect(contents.items.map { $0.table.name } == ["invoices"])

        store.deleteFolder(id: folder.id, connectionId: connectionId)
        await mirror.push()

        contents = try await fixture.core.tableFolders().contents()
        #expect(contents.folders.isEmpty)
        #expect(contents.items.isEmpty)
    }

    @Test("A table folder the core holds and the Mac's store lost comes back into the store")
    func tableFolderFromTheCoreComesBack() async throws {
        let defaults = try fixture.pool.make().defaults
        let mirrorDefaults = try fixture.pool.make().defaults
        let store = TableFolderStorage(
            defaults: defaults,
            syncTracker: try tracker(),
            core: fixture.core,
            mirrorDefaults: mirrorDefaults
        )
        let scope = DatabaseScope(connectionId: connectionId, database: "shop", schema: "public")
        _ = store.createFolder(named: "Billing", in: scope)
        await store.coreMirror?.push()
        let added = TableFolderRecord(
            id: UUID().uuidString,
            connectionId: connectionId.uuidString,
            database: "shop",
            schema: "public",
            name: "Reports",
            createdAtMs: 1_700_000_000_000,
            updatedAtMs: 1_700_000_000_000
        )
        _ = try await fixture.core.tableFolders().writeRecords(write: TableFolderRecordWrite(
            folders: [added],
            items: [],
            removedFolders: [],
            removedItems: []
        ))

        await store.coreMirror?.push()

        let names = store.layout(in: scope).folders.map { $0.name }
        #expect(names == ["Billing", "Reports"])
    }
}
