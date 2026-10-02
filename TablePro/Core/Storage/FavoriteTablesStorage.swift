import Foundation
import os
import TableProPluginKit
import TableProSyncTransport

extension Notification.Name {
    static let favoriteTablesDidChange = Notification.Name("FavoriteTablesDidChange")
}

final class FavoriteTablesStorage: @unchecked Sendable {
    static let shared = FavoriteTablesStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "FavoriteTablesStorage")
    private static let currentSyncIdentityVersion = 1
    private static let escapedPathDomain = "escaped"

    struct FavoriteEntry: Codable, Hashable {
        let connectionId: UUID
        let database: String?
        let schema: String?
        let name: String

        init(connectionId: UUID, database: String?, schema: String?, name: String) {
            self.connectionId = connectionId
            self.database = database?.nilIfEmpty
            self.schema = schema?.nilIfEmpty
            self.name = name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                connectionId: try container.decode(UUID.self, forKey: .connectionId),
                database: try container.decodeIfPresent(String.self, forKey: .database),
                schema: try container.decodeIfPresent(String.self, forKey: .schema),
                name: try container.decode(String.self, forKey: .name)
            )
        }

        private enum CodingKeys: String, CodingKey {
            case connectionId
            case database
            case schema
            case name
        }
    }

    private enum SyncTracking {
        case track
        case discard
    }

    private struct StateChange {
        var removed: Set<FavoriteEntry> = []
        var added: Set<FavoriteEntry> = []

        var changesEntries: Bool { !removed.isEmpty || !added.isEmpty }
    }

    private let defaults: UserDefaults
    private let syncTracker: SyncChangeTracker
    private let key = "com.TablePro.favoriteTables"
    private let syncIdentityVersionKey = "com.TablePro.favoriteTables.syncIdentityVersion"
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

    @MainActor
    func toggle(name: String, schema: String?, database: String?, connectionId: UUID) {
        let entry = FavoriteEntry(connectionId: connectionId, database: database, schema: schema, name: name)
        commit(sync: .track) { favorites in
            guard favorites.remove(entry) == nil else { return }
            favorites.insert(entry)
        }
    }

    @MainActor
    @discardableResult
    func addFavorite(name: String, schema: String?, database: String?, connectionId: UUID) -> Bool {
        let entry = FavoriteEntry(connectionId: connectionId, database: database, schema: schema, name: name)
        return commit(sync: .track) { $0.insert(entry) }.changesEntries
    }

    @MainActor
    func removeFavorite(name: String, schema: String?, database: String?, connectionId: UUID) {
        let entry = FavoriteEntry(connectionId: connectionId, database: database, schema: schema, name: name)
        commit(sync: .track) { $0.remove(entry) }
    }

    @MainActor
    func retarget(connectionId: UUID, _ transform: (FavoriteEntry) -> FavoriteEntry?) {
        commit(sync: .track) { favorites in
            let scoped = favorites.filter { $0.connectionId == connectionId }
            favorites.subtract(scoped)
            favorites.formUnion(scoped.compactMap(transform))
        }
    }

    @MainActor
    @discardableResult
    func removeFavorites(inDatabase database: String?, schema: String?, connectionId: UUID) -> [FavoriteEntry] {
        let database = database?.nilIfEmpty
        let schema = schema?.nilIfEmpty
        let change = commit(sync: .track) { favorites in
            favorites = favorites.filter { entry in
                guard entry.connectionId == connectionId, entry.database == database else { return true }
                guard let schema else { return false }
                return entry.schema != schema
            }
        }
        return Array(change.removed)
    }

    @MainActor
    @discardableResult
    func removeFavorites(for connectionId: UUID) -> [FavoriteEntry] {
        removeFavorites(for: connectionId, sync: .track)
    }

    @MainActor
    @discardableResult
    func removeFavoritesWithoutSync(for connectionId: UUID) -> [FavoriteEntry] {
        removeFavorites(for: connectionId, sync: .discard)
    }

    @MainActor
    private func removeFavorites(for connectionId: UUID, sync: SyncTracking) -> [FavoriteEntry] {
        let change = commit(sync: sync) { favorites in
            favorites = favorites.filter { entry in entry.connectionId != connectionId }
        }
        return Array(change.removed)
    }

    @MainActor
    @discardableResult
    func applyRemote(saved: [FavoriteEntry], deletedIds: Set<String>) -> [UUID: Set<String>] {
        var removedThroughAliases: Set<FavoriteEntry> = []
        let change = mutateState { favorites in
            favorites.formUnion(saved)
            removedThroughAliases = Self.remove(deletedIds, from: &favorites)
        }
        syncTracker.discardDirty(.tableFavorite, ids: Array(deletedIds.union(Self.recordIds(of: change.removed))))
        if change.changesEntries {
            NotificationCenter.default.post(name: .favoriteTablesDidChange, object: self)
        }
        return Self.syncIdsByConnection(of: removedThroughAliases)
    }

    @MainActor
    func migrateSyncIdentityIfNeeded() {
        guard defaults.integer(forKey: syncIdentityVersionKey) < Self.currentSyncIdentityVersion else { return }
        let rekeyed = loadFavorites().filter { Self.legacyAlias(of: $0) != nil }
        let rekeyedIds = Array(Self.recordIds(of: rekeyed))
        syncTracker.markDirty(.tableFavorite, ids: rekeyedIds)
        defaults.set(Self.currentSyncIdentityVersion, forKey: syncIdentityVersionKey)
        guard !rekeyed.isEmpty else { return }
        Self.logger.info("Re-keyed \(rekeyed.count, privacy: .public) favorite tables to escaped sync ids")
    }

    static func syncId(for entry: FavoriteEntry) -> String {
        let path = IdentityPath.joined(identityComponents(of: entry), separator: "|")
        guard path != legacyPath(of: entry) else { return path.sha256 }
        return IdentityPath.joined([escapedPathDomain, path], separator: "|").sha256
    }

    static func legacyAlias(of entry: FavoriteEntry) -> String? {
        let legacy = legacyPath(of: entry)
        guard IdentityPath.joined(identityComponents(of: entry), separator: "|") != legacy else { return nil }
        return legacy.sha256
    }

    static func legacyAliases(of favorites: Set<FavoriteEntry>) -> Set<String> {
        Set(favorites.compactMap(legacyAlias(of:)))
    }

    static func aliasClaims(in favorites: Set<FavoriteEntry>) -> [String: [FavoriteEntry]] {
        var claims: [String: [FavoriteEntry]] = [:]
        for entry in favorites {
            guard let alias = legacyAlias(of: entry) else { continue }
            claims[alias, default: []].append(entry)
        }
        return claims
    }

    private static func identityComponents(of entry: FavoriteEntry) -> [String] {
        [entry.connectionId.uuidString, entry.database ?? "", entry.schema ?? "", entry.name]
    }

    private static func legacyPath(of entry: FavoriteEntry) -> String {
        identityComponents(of: entry).joined(separator: "|")
    }

    @MainActor
    @discardableResult
    private func commit(sync: SyncTracking, _ edit: (inout Set<FavoriteEntry>) -> Void) -> StateChange {
        var remaining: Set<FavoriteEntry> = []
        let change = mutateState { favorites in
            edit(&favorites)
            remaining = favorites
        }
        guard change.changesEntries else { return change }
        let removedIds = Self.recordIdsByConnection(of: change.removed, keepingAliasesOf: remaining)
        switch sync {
        case .track:
            let reclaimedAliases = Self.legacyAliases(of: change.removed).intersection(Self.legacyAliases(of: remaining))
            syncTracker.markDeleted(.tableFavorite, idsByOwner: removedIds)
            syncTracker.markDirty(.tableFavorite, ids: Array(Self.recordIds(of: change.added).union(reclaimedAliases)))
        case .discard:
            syncTracker.discardDirty(.tableFavorite, ids: removedIds.values.flatMap { $0 })
        }
        NotificationCenter.default.post(name: .favoriteTablesDidChange, object: self)
        return change
    }

    @discardableResult
    private func mutateState(_ edit: (inout Set<FavoriteEntry>) -> Void) -> StateChange {
        lock.lock()
        defer { lock.unlock() }
        let previous = _loadFavorites()
        var favorites = previous
        edit(&favorites)
        let change = StateChange(removed: previous.subtracting(favorites), added: favorites.subtracting(previous))
        if change.changesEntries {
            _persist(favorites)
        }
        return change
    }

    private static func recordIds(of favorites: Set<FavoriteEntry>) -> Set<String> {
        Set(favorites.map(syncId(for:))).union(legacyAliases(of: favorites))
    }

    private static func recordIdsByConnection(
        of removed: Set<FavoriteEntry>,
        keepingAliasesOf remaining: Set<FavoriteEntry>
    ) -> [UUID: Set<String>] {
        let claimedAliases = legacyAliases(of: remaining)
        var ids: [UUID: Set<String>] = [:]
        for entry in removed {
            ids[entry.connectionId, default: []].insert(syncId(for: entry))
            guard let alias = legacyAlias(of: entry), !claimedAliases.contains(alias) else { continue }
            ids[entry.connectionId, default: []].insert(alias)
        }
        return ids
    }

    private static func syncIdsByConnection(of entries: Set<FavoriteEntry>) -> [UUID: Set<String>] {
        Dictionary(grouping: entries, by: \.connectionId).mapValues { Set($0.map(syncId(for:))) }
    }

    private static func remove(_ deletedIds: Set<String>, from favorites: inout Set<FavoriteEntry>) -> Set<FavoriteEntry> {
        guard !deletedIds.isEmpty else { return [] }
        let entriesById = Dictionary(favorites.map { (syncId(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        let claims = aliasClaims(in: favorites)
        var removedThroughAliases: Set<FavoriteEntry> = []
        for id in deletedIds {
            if let entry = entriesById[id] {
                favorites.remove(entry)
                continue
            }
            guard let claimants = claims[id] else { continue }
            guard claimants.count == 1, let entry = claimants.first else {
                logger.warning("Kept \(claimants.count, privacy: .public) favorite tables sharing one retired sync id")
                continue
            }
            favorites.remove(entry)
            removedThroughAliases.insert(entry)
        }
        return removedThroughAliases.filter { !deletedIds.contains(syncId(for: $0)) }
    }

    private func _loadFavorites() -> Set<FavoriteEntry> {
        if let cache { return cache }
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([FavoriteEntry].self, from: data) else {
            cache = []
            return []
        }
        let favorites = Set(stored)
        guard favorites.count == stored.count else {
            _persist(favorites)
            return favorites
        }
        cache = favorites
        return favorites
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
