//
//  FavoriteDatabasesStorage.swift
//  TablePro
//

import Foundation
import TableProSyncTransport

extension Notification.Name {
    internal static let favoriteDatabasesDidChange = Notification.Name("FavoriteDatabasesDidChange")
}

// One key for every connection, so a sync push resolves a dirty id without knowing the connections. `FavoriteTablesStorage` is the same shape.
@MainActor
internal final class FavoriteDatabasesStorage {
    internal static let shared = FavoriteDatabasesStorage(core: .shared)

    private static let storageKey = JSONDefaultsKey<Set<FavoriteDatabaseEntry>>("com.TablePro.favoriteDatabases")

    private let defaults: UserDefaults
    private let syncTracker: SyncChangeTracker
    private var cache: Set<FavoriteDatabaseEntry>?
    // Nil keeps the favourites out of the core, for a store nothing else reads.
    internal private(set) var coreMirror: CoreMirror<FavoriteDatabasesCoreAdapter>?

    internal init(
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        syncTracker: SyncChangeTracker = .shared,
        core: CoreHistoryDatabase? = nil
    ) {
        self.defaults = defaults
        self.syncTracker = syncTracker
        if let core {
            coreMirror = CoreMirror(adapter: FavoriteDatabasesCoreAdapter(store: self, database: core), defaults: defaults)
        }
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

    // No environment in the id: re-tagging a database would orphan the old record and push a second one.
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
        coreMirror?.schedulePush()
        postChangeNotification()
    }

    // False when favourites are stored and do not decode, which reads as none and must not read as none removed.
    internal var storedFavoritesRead: Bool {
        !defaults.read(Self.storageKey).isUnreadable
    }

    // The core's copy written back, marking nothing: it came from this Mac or a pull, never a new edit here.
    internal func applyCoreFavorites(puts: [FavoriteDatabaseEntry], removals: [String]) {
        let removed = Set(removals)
        var favorites = loadFavorites().filter { !removed.contains($0.id) }
        for entry in puts {
            Self.upsert(entry, into: &favorites)
        }
        guard favorites != loadFavorites() else { return }
        persist(favorites)
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
