import Foundation
import os

extension Notification.Name {
    static let favoriteTablesDidChange = Notification.Name("FavoriteTablesDidChange")
}

final class FavoriteTablesStorage {
    static let shared = FavoriteTablesStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "FavoriteTablesStorage")

    struct FavoriteEntry: Codable, Hashable {
        let connectionId: UUID
        let database: String?
        let schema: String?
        let name: String
    }

    private let defaults: UserDefaults
    private let syncTracker: SyncChangeTracker
    private let key = "com.TablePro.favoriteTables"
    private var cache: Set<FavoriteEntry>?
    private let lock = NSLock()

    init(userDefaults: UserDefaults = .standard, syncTracker: SyncChangeTracker = .shared) {
        self.defaults = userDefaults
        self.syncTracker = syncTracker
    }

    func loadFavorites() -> Set<FavoriteEntry> {
        lock.lock()
        defer { lock.unlock() }
        return _loadFavorites()
    }

    func favorites(for connectionId: UUID) -> Set<FavoriteEntry> {
        lock.lock()
        defer { lock.unlock() }
        return _loadFavorites().filter { $0.connectionId == connectionId }
    }

    func isFavorite(name: String, schema: String?, database: String?, connectionId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _loadFavorites().contains(
            FavoriteEntry(connectionId: connectionId, database: database, schema: schema, name: name)
        )
    }

    func toggle(name: String, schema: String?, database: String?, connectionId: UUID) {
        let entry = FavoriteEntry(connectionId: connectionId, database: database, schema: schema, name: name)
        let action: TrackedAction = mutate { favorites in
            if favorites.contains(entry) {
                favorites.remove(entry)
                return .removed(entry)
            }
            favorites.insert(entry)
            return .added(entry)
        }
        notify(after: action)
    }

    @discardableResult
    func addFavorite(name: String, schema: String?, database: String?, connectionId: UUID) -> Bool {
        let entry = FavoriteEntry(connectionId: connectionId, database: database, schema: schema, name: name)
        let action: TrackedAction = mutate { favorites in
            guard favorites.insert(entry).inserted else { return .noChange }
            return .added(entry)
        }
        notify(after: action)
        return action.changed
    }

    @discardableResult
    func addFavoriteWithoutSync(_ entry: FavoriteEntry) -> Bool {
        let action = mutate { favorites in
            favorites.insert(entry).inserted ? .added(entry) : .noChange
        }
        notify(after: action, skipSync: true)
        return action.changed
    }

    func removeFavorite(name: String, schema: String?, database: String?, connectionId: UUID) {
        let entry = FavoriteEntry(connectionId: connectionId, database: database, schema: schema, name: name)
        let action = mutate { favorites in
            favorites.remove(entry) != nil ? .removed(entry) : .noChange
        }
        notify(after: action)
    }

    func removeFavoriteWithoutSync(_ entry: FavoriteEntry) {
        let action = mutate { favorites in
            favorites.remove(entry) != nil ? .removed(entry) : .noChange
        }
        notify(after: action, skipSync: true)
    }

    func removeFavoriteWithoutSync(id: String) {
        let action = mutate { favorites in
            guard let entry = favorites.first(where: { Self.syncId(for: $0) == id }) else { return .noChange }
            favorites.remove(entry)
            return .removed(entry)
        }
        notify(after: action, skipSync: true)
    }

    @discardableResult
    func removeFavorites(for connectionId: UUID) -> [FavoriteEntry] {
        var removed: [FavoriteEntry] = []
        lock.lock()
        var favorites = _loadFavorites()
        let toRemove = favorites.filter { $0.connectionId == connectionId }
        if !toRemove.isEmpty {
            favorites.subtract(toRemove)
            _persist(favorites)
            removed = Array(toRemove)
        }
        lock.unlock()

        guard !removed.isEmpty else { return [] }
        for entry in removed {
            syncTracker.markDeleted(.tableFavorite, id: Self.syncId(for: entry))
        }
        NotificationCenter.default.post(name: .favoriteTablesDidChange, object: nil)
        return removed
    }

    static func syncId(for entry: FavoriteEntry) -> String {
        let raw = entry.connectionId.uuidString
            + "|" + (entry.database ?? "")
            + "|" + (entry.schema ?? "")
            + "|" + entry.name
        return raw.sha256
    }

    private enum TrackedAction {
        case noChange
        case added(FavoriteEntry)
        case removed(FavoriteEntry)

        var changed: Bool {
            if case .noChange = self { return false }
            return true
        }
    }

    private func mutate(_ block: (inout Set<FavoriteEntry>) -> TrackedAction) -> TrackedAction {
        lock.lock()
        defer { lock.unlock() }
        var favorites = _loadFavorites()
        let action = block(&favorites)
        guard action.changed else { return action }
        _persist(favorites)
        return action
    }

    private func notify(after action: TrackedAction, skipSync: Bool = false) {
        switch action {
        case .noChange:
            return
        case .added(let entry):
            if !skipSync {
                syncTracker.markDirty(.tableFavorite, id: Self.syncId(for: entry))
            }
            NotificationCenter.default.post(name: .favoriteTablesDidChange, object: nil)
        case .removed(let entry):
            if !skipSync {
                syncTracker.markDeleted(.tableFavorite, id: Self.syncId(for: entry))
            }
            NotificationCenter.default.post(name: .favoriteTablesDidChange, object: nil)
        }
    }

    private func _loadFavorites() -> Set<FavoriteEntry> {
        if let cache { return cache }
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Set<FavoriteEntry>.self, from: data) else {
            cache = []
            return []
        }
        cache = decoded
        return decoded
    }

    private func _persist(_ favorites: Set<FavoriteEntry>) {
        cache = favorites
        guard let data = try? JSONEncoder().encode(favorites) else {
            Self.logger.error("Failed to encode favorite tables")
            return
        }
        defaults.set(data, forKey: key)
    }
}
