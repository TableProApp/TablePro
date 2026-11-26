//
//  FavoriteDatabasesStorage.swift
//  TablePro
//

import Foundation
import TableProSyncTransport

extension Notification.Name {
    internal static let favoriteDatabasesDidChange = Notification.Name("FavoriteDatabasesDidChange")
}

// One key for every connection. `FavoriteTablesStorage` is the same shape.
@MainActor
internal final class FavoriteDatabasesStorage {
    internal static let shared = FavoriteDatabasesStorage()

    private static let storageKey = JSONDefaultsKey<Set<FavoriteDatabaseEntry>>("com.TablePro.favoriteDatabases")

    private let defaults: UserDefaults
    private let syncJournal: SyncHostJournal
    private var cache: Set<FavoriteDatabaseEntry>?

    internal init(
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        syncJournal: SyncHostJournal = .shared
    ) {
        self.defaults = defaults
        self.syncJournal = syncJournal
    }

    internal func loadFavorites() -> Set<FavoriteDatabaseEntry> {
        if let cache { return cache }
        let valid = (defaults.read(Self.storageKey).value ?? []).filter { !$0.database.isEmpty }
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
        commit { Self.upsert(entry, into: &$0) }
    }

    internal func rename(database oldName: String, to newName: String, connectionId: UUID) {
        commit { favorites in
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
        commit { favorites in
            favorites = favorites.filter { !($0.connectionId == connectionId && $0.database == database) }
        }
    }

    internal func removeFavorites(for connectionId: UUID) {
        commit { favorites in
            favorites = favorites.filter { $0.connectionId != connectionId }
        }
    }

    // No environment in the id: re-tagging a database would orphan the old record and push a second one.
    nonisolated internal static func syncId(for entry: FavoriteDatabaseEntry) -> String {
        (entry.connectionId.uuidString + "|" + entry.database).sha256
    }

    private static func upsert(_ entry: FavoriteDatabaseEntry, into favorites: inout Set<FavoriteDatabaseEntry>) {
        guard !entry.database.isEmpty else { return }
        if let existing = favorites.first(where: { $0.id == entry.id }) {
            guard existing.environment != entry.environment else { return }
            favorites.remove(existing)
        }
        favorites.insert(entry)
    }

    private func commit(_ edit: (inout Set<FavoriteDatabaseEntry>) -> Void) {
        let previous = loadFavorites()
        var favorites = previous
        edit(&favorites)
        let previousById = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIds = Set(favorites.map(\.id))
        let removed = previous.filter { !currentIds.contains($0.id) }
        let changedIds = favorites.filter { previousById[$0.id] != $0 }.map(Self.syncId(for:))
        guard !removed.isEmpty || !changedIds.isEmpty else { return }

        persist(favorites)
        syncJournal.recorded(.favoriteDatabase, written: changedIds, deleted: removed.map(Self.syncId(for:)))
        postChangeNotification()
    }

    private func postChangeNotification() {
        NotificationCenter.default.post(name: .favoriteDatabasesDidChange, object: self)
    }

    private func persist(_ favorites: Set<FavoriteDatabaseEntry>) {
        cache = favorites
        guard !favorites.isEmpty else {
            defaults.removeValue(for: Self.storageKey)
            return
        }
        try? defaults.write(favorites, to: Self.storageKey)
    }
}
