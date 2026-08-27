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
        notify(after: mutate { Self.upsert(entry, into: &$0) })
    }

    internal func setFavoriteWithoutSync(_ entry: FavoriteDatabaseEntry) {
        notify(after: mutate { Self.upsert(entry, into: &$0) }, skipSync: true)
    }

    /// A favourite follows its database's new name rather than being dropped, because the tag the
    /// user put on it is about the database, not about what it is called. It is synced, so the
    /// entry is written before the removal is announced.
    internal func rename(database oldName: String, to newName: String, connectionId: UUID) {
        guard let existing = favorites(for: connectionId).first(where: { $0.database == oldName }) else { return }
        setFavorite(database: newName, environment: existing.environment, connectionId: connectionId)
        removeFavorite(database: oldName, connectionId: connectionId)
    }

    internal func removeFavorite(database: String, connectionId: UUID) {
        notify(after: mutate { favorites in
            guard let existing = favorites.first(where: {
                $0.connectionId == connectionId && $0.database == database
            }) else { return .noChange }
            favorites.remove(existing)
            return .removed(existing)
        })
    }

    internal func removeFavoriteWithoutSync(id: String) {
        notify(after: mutate { favorites in
            guard let entry = favorites.first(where: { Self.syncId(for: $0) == id }) else { return .noChange }
            favorites.remove(entry)
            return .removed(entry)
        }, skipSync: true)
    }

    internal func removeFavorites(for connectionId: UUID) {
        removeFavorites(for: connectionId, skipSync: false)
    }

    internal func removeFavoritesWithoutSync(for connectionId: UUID) {
        removeFavorites(for: connectionId, skipSync: true)
    }

    /// The composite id never includes the environment. A record keyed on a mutable payload is
    /// orphaned the moment that payload changes, so re-tagging a database would leave the old
    /// record behind and push a second one beside it.
    nonisolated internal static func syncId(for entry: FavoriteDatabaseEntry) -> String {
        (entry.connectionId.uuidString + "|" + entry.database).sha256
    }

    private func removeFavorites(for connectionId: UUID, skipSync: Bool) {
        var favorites = loadFavorites()
        let removed = favorites.filter { $0.connectionId == connectionId }
        guard !removed.isEmpty else { return }
        favorites.subtract(removed)
        persist(favorites)

        guard !skipSync else {
            postChangeNotification()
            return
        }
        for entry in removed {
            syncTracker.markDeleted(.favoriteDatabase, id: Self.syncId(for: entry))
        }
        postChangeNotification()
    }

    private enum TrackedAction {
        case noChange
        case changed(FavoriteDatabaseEntry)
        case removed(FavoriteDatabaseEntry)
    }

    /// Re-picking the environment a database already has is not a change. Persisting it anyway
    /// posts a notification that rebuilds every visible tree row in every window for nothing.
    private static func upsert(
        _ entry: FavoriteDatabaseEntry,
        into favorites: inout Set<FavoriteDatabaseEntry>
    ) -> TrackedAction {
        guard !entry.database.isEmpty else { return .noChange }
        if let existing = favorites.first(where: { $0.id == entry.id }) {
            guard existing.environment != entry.environment else { return .noChange }
            favorites.remove(existing)
        }
        favorites.insert(entry)
        return .changed(entry)
    }

    private func mutate(_ block: (inout Set<FavoriteDatabaseEntry>) -> TrackedAction) -> TrackedAction {
        var favorites = loadFavorites()
        let action = block(&favorites)
        guard case .noChange = action else {
            persist(favorites)
            return action
        }
        return action
    }

    /// Persist first, then notify: `markDeleted` posts a change that can start a sync, and a sync
    /// that reads a file still holding the deleted entry re-uploads it.
    private func notify(after action: TrackedAction, skipSync: Bool = false) {
        switch action {
        case .noChange:
            return
        case .changed(let entry):
            if !skipSync {
                syncTracker.markDirty(.favoriteDatabase, id: Self.syncId(for: entry))
            }
            postChangeNotification()
        case .removed(let entry):
            if !skipSync {
                syncTracker.markDeleted(.favoriteDatabase, id: Self.syncId(for: entry))
            }
            postChangeNotification()
        }
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
            Self.logger.error("Failed to encode favorite databases: \(error.localizedDescription, privacy: .public)")
        }
    }
}
