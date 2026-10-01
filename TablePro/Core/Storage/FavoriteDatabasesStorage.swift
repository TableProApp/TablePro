//
//  FavoriteDatabasesStorage.swift
//  TablePro
//

import Foundation
import os
import TableProSyncTransport

extension Notification.Name {
    internal static let favoriteDatabasesDidChange = Notification.Name("FavoriteDatabasesDidChange")
}

/// Every entry lives under one key rather than one key per connection, so a sync push can resolve a
/// dirty id back to its entry without knowing which connections exist, and so deleting a connection
/// leaves nothing behind to forget. `FavoriteTablesStorage` is the same shape.
@MainActor
internal final class FavoriteDatabasesStorage {
    internal static let shared = FavoriteDatabasesStorage()

    private static let logger = Logger(subsystem: "com.TablePro", category: "FavoriteDatabasesStorage")
    private static let storageKey = "com.TablePro.favoriteDatabases"

    private let defaults: UserDefaults
    private let syncTracker: SyncChangeTracker
    private var cache: Set<FavoriteDatabaseEntry>?

    internal init(
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        syncTracker: SyncChangeTracker = .shared
    ) {
        self.defaults = defaults
        self.syncTracker = syncTracker
    }

    internal func loadFavorites() -> Set<FavoriteDatabaseEntry> {
        if let cache { return cache }
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(Set<FavoriteDatabaseEntry>.self, from: data)
        else {
            cache = []
            return []
        }
        let valid = decoded.filter { !$0.database.isEmpty }
        cache = valid
        return valid
    }

    internal func favorites(for connectionId: UUID) -> Set<FavoriteDatabaseEntry> {
        loadFavorites().filter { $0.connectionId == connectionId }
    }

    internal func setFavorite(
        database: String,
        environment: FavoriteDatabaseEnvironment,
        connectionId: UUID
    ) {
        let entry = FavoriteDatabaseEntry(
            connectionId: connectionId,
            database: database,
            environment: environment
        )
        commit(sync: .track) { Self.upsert(entry, into: &$0) }
    }

    internal func setFavoriteWithoutSync(_ entry: FavoriteDatabaseEntry) {
        commit(sync: .discard) { Self.upsert(entry, into: &$0) }
    }

    internal func rename(database oldName: String, to newName: String, connectionId: UUID) {
        commit(sync: .track) { favorites in
            guard let existing = favorites.first(where: {
                $0.connectionId == connectionId && $0.database == oldName
            }) else { return }
            favorites.remove(existing)
            Self.upsert(
                FavoriteDatabaseEntry(connectionId: connectionId, database: newName, environment: existing.environment),
                into: &favorites
            )
        }
    }

    internal func removeFavorite(database: String, connectionId: UUID) {
        commit(sync: .track) { favorites in
            favorites = favorites.filter { !($0.connectionId == connectionId && $0.database == database) }
        }
    }

    internal func removeFavoritesWithoutSync(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        commit(sync: .discard) { favorites in
            favorites = favorites.filter { !ids.contains(Self.syncId(for: $0)) }
        }
    }

    internal func removeFavorites(for connectionId: UUID) {
        commit(sync: .track) { favorites in
            favorites = favorites.filter { $0.connectionId != connectionId }
        }
    }

    internal func removeFavoritesWithoutSync(for connectionId: UUID) {
        commit(sync: .discard) { favorites in
            favorites = favorites.filter { $0.connectionId != connectionId }
        }
    }

    /// The composite id never includes the environment. A record keyed on a mutable payload is
    /// orphaned the moment that payload changes, so re-tagging a database would leave the old
    /// record behind and push a second one beside it.
    nonisolated internal static func syncId(for entry: FavoriteDatabaseEntry) -> String {
        (entry.connectionId.uuidString + "|" + entry.database).sha256
    }

    private enum SyncTracking {
        case track
        case discard
    }

    private static func syncIdsByConnection(of entries: Set<FavoriteDatabaseEntry>) -> [UUID: Set<String>] {
        Dictionary(grouping: entries, by: \.connectionId).mapValues { Set($0.map(syncId(for:))) }
    }

    private static func upsert(_ entry: FavoriteDatabaseEntry, into favorites: inout Set<FavoriteDatabaseEntry>) {
        guard !entry.database.isEmpty else { return }
        if let existing = favorites.first(where: { $0.id == entry.id }) {
            guard existing.environment != entry.environment else { return }
            favorites.remove(existing)
        }
        favorites.insert(entry)
    }

    private func commit(sync: SyncTracking, _ edit: (inout Set<FavoriteDatabaseEntry>) -> Void) {
        let previous = loadFavorites()
        var favorites = previous
        edit(&favorites)
        let previousById = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIds = Set(favorites.map(\.id))
        let removed = previous.filter { !currentIds.contains($0.id) }
        let changedIds = favorites.filter { previousById[$0.id] != $0 }.map(Self.syncId(for:))
        guard !removed.isEmpty || !changedIds.isEmpty else { return }

        persist(favorites)
        switch sync {
        case .track:
            syncTracker.markDeleted(.favoriteDatabase, idsByOwner: Self.syncIdsByConnection(of: removed))
            syncTracker.markDirty(.favoriteDatabase, ids: changedIds)
        case .discard:
            syncTracker.discardDirty(.favoriteDatabase, ids: removed.map(Self.syncId(for:)))
        }
        postChangeNotification()
    }

    private func postChangeNotification() {
        NotificationCenter.default.post(name: .favoriteDatabasesDidChange, object: self)
    }

    private func persist(_ favorites: Set<FavoriteDatabaseEntry>) {
        cache = favorites
        guard !favorites.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(favorites), forKey: Self.storageKey)
        } catch {
            Self.logger.error("Failed to encode favorite databases: \(error.publicLogShape, privacy: .public)")
        }
    }
}
