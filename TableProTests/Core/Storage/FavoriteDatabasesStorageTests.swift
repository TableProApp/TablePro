//
//  FavoriteDatabasesStorageTests.swift
//  TableProTests
//

import Foundation
import Testing
import TableProSyncTransport

@testable import TablePro

@MainActor
@Suite("FavoriteDatabasesStorage")
struct FavoriteDatabasesStorageTests {
    private static let storageKey = "com.TablePro.favoriteDatabases"

    private func makeStorage() throws -> (FavoriteDatabasesStorage, UserDefaults, SyncMetadataStorage) {
        let favoritesSuite = "FavoriteDatabasesStorageTests.favorites.\(UUID().uuidString)"
        let syncSuite = "FavoriteDatabasesStorageTests.sync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: favoritesSuite))
        let syncDefaults = try #require(UserDefaults(suiteName: syncSuite))
        defaults.removePersistentDomain(forName: favoritesSuite)
        syncDefaults.removePersistentDomain(forName: syncSuite)

        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        let storage = FavoriteDatabasesStorage(
            defaults: defaults,
            syncTracker: SyncChangeTracker(metadataStorage: metadata)
        )
        return (storage, defaults, metadata)
    }

    private func store(_ json: String, in defaults: UserDefaults) {
        defaults.set(Data(json.utf8), forKey: Self.storageKey)
    }

    @Test("Favorite identity includes the connection")
    func favoritesAreConnectionScoped() throws {
        let (storage, _, _) = try makeStorage()
        let first = UUID()
        let second = UUID()

        storage.setFavorite(database: "app", environment: .development, connectionId: first)
        storage.setFavorite(database: "app", environment: .production, connectionId: second)

        #expect(storage.favorites(for: first).first?.environment == .development)
        #expect(storage.favorites(for: second).first?.environment == .production)
    }

    @Test("Changing an environment replaces the favorite instead of duplicating it")
    func environmentUpdateReplacesEntry() throws {
        let (storage, _, _) = try makeStorage()
        let connectionId = UUID()

        storage.setFavorite(database: "orders", environment: .development, connectionId: connectionId)
        storage.setFavorite(database: "orders", environment: .testing, connectionId: connectionId)

        let entries = storage.favorites(for: connectionId)
        #expect(entries.count == 1)
        #expect(entries.first?.environment == .testing)
    }

    @Test("Removing one database preserves the connection's other favorites")
    func removePreservesOtherEntries() throws {
        let (storage, _, _) = try makeStorage()
        let connectionId = UUID()
        storage.setFavorite(database: "app", environment: .development, connectionId: connectionId)
        storage.setFavorite(database: "audit", environment: .testing, connectionId: connectionId)

        storage.removeFavorite(database: "app", connectionId: connectionId)

        #expect(storage.favorites(for: connectionId).map(\.database) == ["audit"])
    }

    @Test("An unknown stored environment falls back to Unassigned")
    func unknownEnvironmentFallsBack() throws {
        let (storage, defaults, _) = try makeStorage()
        let connectionId = UUID()
        store(
            """
            [{"connectionId":"\(connectionId.uuidString)","database":"future","environment":"staging"}]
            """,
            in: defaults
        )

        #expect(storage.favorites(for: connectionId).first?.environment == .unassigned)
    }

    @Test("Malformed storage reads as no favorites rather than crashing")
    func malformedStorageReturnsEmpty() throws {
        let (storage, defaults, _) = try makeStorage()
        store("not-json", in: defaults)

        #expect(storage.loadFavorites().isEmpty)
    }

    @Test("A favorite belongs only to the connection it names")
    func ignoresEntriesFromAnotherConnection() throws {
        let (storage, defaults, _) = try makeStorage()
        let requested = UUID()
        let foreign = UUID()
        store(
            """
            [{"connectionId":"\(foreign.uuidString)","database":"private","environment":"production"}]
            """,
            in: defaults
        )

        #expect(storage.favorites(for: requested).isEmpty)
        #expect(storage.favorites(for: foreign).map(\.database) == ["private"])
    }

    @Test("Deleting a connection removes its favorites and leaves the others alone")
    func removeConnectionFavorites() throws {
        let (storage, _, _) = try makeStorage()
        let deleted = UUID()
        let kept = UUID()
        storage.setFavorite(database: "app", environment: .production, connectionId: deleted)
        storage.setFavorite(database: "app", environment: .production, connectionId: kept)

        storage.removeFavorites(for: deleted)

        #expect(storage.favorites(for: deleted).isEmpty)
        #expect(storage.favorites(for: kept).map(\.database) == ["app"])
    }

    // MARK: - Change notification

    @Test("Re-picking the environment a database already has changes nothing")
    func settingTheSameEnvironmentIsANoOp() throws {
        let (storage, _, metadata) = try makeStorage()
        let connectionId = UUID()
        storage.setFavorite(database: "app", environment: .production, connectionId: connectionId)
        metadata.clearDirty(type: .favoriteDatabase)

        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .favoriteDatabasesDidChange, object: nil, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        storage.setFavorite(database: "app", environment: .production, connectionId: connectionId)

        #expect(notifications == 0)
        #expect(metadata.dirtyIds(for: .favoriteDatabase).isEmpty)
    }

    @Test("Removing a database that is not a favorite changes nothing")
    func removingAnAbsentFavoriteIsANoOp() throws {
        let (storage, _, metadata) = try makeStorage()
        let connectionId = UUID()

        storage.removeFavorite(database: "missing", connectionId: connectionId)

        #expect(metadata.tombstones(for: .favoriteDatabase).isEmpty)
    }

    // MARK: - Sync

    @Test("Adding a favorite marks its sync id dirty")
    func addMarksDirty() throws {
        let (storage, _, metadata) = try makeStorage()
        let connectionId = UUID()
        storage.setFavorite(database: "app", environment: .development, connectionId: connectionId)

        let entry = FavoriteDatabaseEntry(
            connectionId: connectionId,
            database: "app",
            environment: .development
        )
        #expect(metadata.dirtyIds(for: .favoriteDatabase) == [FavoriteDatabasesStorage.syncId(for: entry)])
    }

    /// The record is keyed on identity alone. Hashing the environment into it would orphan the old
    /// record on every re-tag and push a second one beside it.
    @Test("Re-tagging a database keeps its sync id")
    func syncIdIgnoresEnvironment() {
        let connectionId = UUID()
        let development = FavoriteDatabaseEntry(
            connectionId: connectionId,
            database: "app",
            environment: .development
        )
        let production = FavoriteDatabaseEntry(
            connectionId: connectionId,
            database: "app",
            environment: .production
        )

        #expect(
            FavoriteDatabasesStorage.syncId(for: development)
                == FavoriteDatabasesStorage.syncId(for: production)
        )
    }

    @Test("Two connections with the same database name get different sync ids")
    func syncIdIncludesConnection() {
        let first = FavoriteDatabaseEntry(connectionId: UUID(), database: "app", environment: .development)
        let second = FavoriteDatabaseEntry(connectionId: UUID(), database: "app", environment: .development)

        #expect(FavoriteDatabasesStorage.syncId(for: first) != FavoriteDatabasesStorage.syncId(for: second))
    }

    @Test("Removing a favorite creates a sync tombstone")
    func removeCreatesTombstone() throws {
        let (storage, _, metadata) = try makeStorage()
        let connectionId = UUID()
        storage.setFavorite(database: "app", environment: .development, connectionId: connectionId)
        storage.removeFavorite(database: "app", connectionId: connectionId)

        let entry = FavoriteDatabaseEntry(
            connectionId: connectionId,
            database: "app",
            environment: .development
        )
        let id = FavoriteDatabasesStorage.syncId(for: entry)
        #expect(metadata.dirtyIds(for: .favoriteDatabase).isEmpty)
        #expect(metadata.tombstones(for: .favoriteDatabase).contains { $0.id == id })
    }

    @Test("Remote apply helpers track no local change")
    func withoutSyncTracksNothing() throws {
        let (storage, _, metadata) = try makeStorage()
        let connectionId = UUID()
        let entry = FavoriteDatabaseEntry(
            connectionId: connectionId,
            database: "orders",
            environment: .testing
        )

        storage.setFavoriteWithoutSync(entry)
        #expect(storage.favorites(for: connectionId).first?.environment == .testing)

        storage.removeFavoriteWithoutSync(id: FavoriteDatabasesStorage.syncId(for: entry))
        #expect(storage.favorites(for: connectionId).isEmpty)
        #expect(metadata.dirtyIds(for: .favoriteDatabase).isEmpty)
        #expect(metadata.tombstones(for: .favoriteDatabase).isEmpty)
    }

    /// A remote apply carries a payload, so it has to overwrite rather than insert-if-absent.
    @Test("A remote apply overwrites the local environment")
    func remoteApplyOverwritesEnvironment() throws {
        let (storage, _, _) = try makeStorage()
        let connectionId = UUID()
        storage.setFavorite(database: "app", environment: .development, connectionId: connectionId)

        storage.setFavoriteWithoutSync(
            FavoriteDatabaseEntry(connectionId: connectionId, database: "app", environment: .production)
        )

        #expect(storage.favorites(for: connectionId).map(\.environment) == [.production])
    }

    @Test("Deleting a connection remotely leaves no tombstone to push back")
    func remoteConnectionDeleteTracksNothing() throws {
        let (storage, _, metadata) = try makeStorage()
        let connectionId = UUID()
        storage.setFavoriteWithoutSync(
            FavoriteDatabaseEntry(connectionId: connectionId, database: "app", environment: .production)
        )

        storage.removeFavoritesWithoutSync(for: connectionId)

        #expect(storage.favorites(for: connectionId).isEmpty)
        #expect(metadata.tombstones(for: .favoriteDatabase).isEmpty)
    }
}
