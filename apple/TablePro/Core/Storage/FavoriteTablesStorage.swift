import Foundation
import os
import TableProPluginKit
import TableProSyncTransport

extension Notification.Name {
    static let favoriteTablesDidChange = Notification.Name("FavoriteTablesDidChange")
}

final class FavoriteTablesStorage: @unchecked Sendable {
    static let shared = FavoriteTablesStorage(core: .shared)
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

    private struct StateChange {
        var removed: Set<FavoriteEntry> = []
        var added: Set<FavoriteEntry> = []

        var changesEntries: Bool { !removed.isEmpty || !added.isEmpty }
    }

    private let defaults: UserDefaults
    private let syncJournal: SyncHostJournal
    private let key = "com.TablePro.favoriteTables"
    private let syncIdentityVersionKey = "com.TablePro.favoriteTables.syncIdentityVersion"
    private var cache: Set<FavoriteEntry>?
    private let lock = NSLock()
    // Nil keeps the favourites out of the core, for a store nothing else reads.
    private(set) var coreMirror: CoreMirror<FavoriteTablesCoreAdapter>?

    init(
        userDefaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        syncJournal: SyncHostJournal = .shared,
        core: CoreHistoryDatabase? = nil
    ) {
        self.defaults = userDefaults
        self.syncJournal = syncJournal
        if let core {
            coreMirror = CoreMirror(adapter: FavoriteTablesCoreAdapter(store: self, database: core), defaults: userDefaults)
        }
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
        commit { favorites in
            guard favorites.remove(entry) == nil else { return }
            favorites.insert(entry)
        }
    }

    @MainActor
    @discardableResult
    func addFavorite(name: String, schema: String?, database: String?, connectionId: UUID) -> Bool {
        let entry = FavoriteEntry(connectionId: connectionId, database: database, schema: schema, name: name)
        return commit { $0.insert(entry) }.changesEntries
    }

    @MainActor
    func removeFavorite(name: String, schema: String?, database: String?, connectionId: UUID) {
        let entry = FavoriteEntry(connectionId: connectionId, database: database, schema: schema, name: name)
        commit { $0.remove(entry) }
    }

    @MainActor
    func retarget(connectionId: UUID, _ transform: (FavoriteEntry) -> FavoriteEntry?) {
        commit { favorites in
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
        let change = commit { favorites in
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
        let change = commit { favorites in
            favorites = favorites.filter { entry in entry.connectionId != connectionId }
        }
        return Array(change.removed)
    }

    @MainActor
    func migrateSyncIdentityIfNeeded() {
        guard defaults.integer(forKey: syncIdentityVersionKey) < Self.currentSyncIdentityVersion else { return }
        let rekeyed = loadFavorites().filter { Self.legacyAlias(of: $0) != nil }
        let rekeyedIds = Array(Self.recordIds(of: rekeyed))
        syncJournal.recorded(.tableFavorite, written: rekeyedIds)
        defaults.set(Self.currentSyncIdentityVersion, forKey: syncIdentityVersionKey)
        guard !rekeyed.isEmpty else { return }
        Self.logger.info("Re-keyed \(rekeyed.count, privacy: .public) favorite tables to escaped sync ids")
    }

    // False when favourites are stored and do not decode, which reads as none and must not read as none removed.
    var storedFavoritesRead: Bool {
        guard let data = defaults.data(forKey: key) else { return true }
        return (try? JSONDecoder().decode([FavoriteEntry].self, from: data)) != nil
    }

    // The core's copy written back, marking nothing: it came from this Mac or a pull, never a new edit here.
    @MainActor
    func applyCoreFavorites(puts: [FavoriteEntry], removals: [FavoriteEntry]) {
        let change = mutateState { favorites in
            favorites.subtract(removals)
            favorites.formUnion(puts)
        }
        if change.changesEntries {
            NotificationCenter.default.post(name: .favoriteTablesDidChange, object: self)
        }
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

    private static func identityComponents(of entry: FavoriteEntry) -> [String] {
        [entry.connectionId.uuidString, entry.database ?? "", entry.schema ?? "", entry.name]
    }

    private static func legacyPath(of entry: FavoriteEntry) -> String {
        identityComponents(of: entry).joined(separator: "|")
    }

    @MainActor
    @discardableResult
    private func commit(_ edit: (inout Set<FavoriteEntry>) -> Void) -> StateChange {
        var remaining: Set<FavoriteEntry> = []
        let change = mutateState { favorites in
            edit(&favorites)
            remaining = favorites
        }
        guard change.changesEntries else { return change }
        let reclaimedAliases = Self.legacyAliases(of: change.removed).intersection(Self.legacyAliases(of: remaining))
        syncJournal.recorded(
            .tableFavorite,
            written: Array(Self.recordIds(of: change.added).union(reclaimedAliases)),
            deleted: Array(Self.recordIds(ofRemoved: change.removed, keepingAliasesOf: remaining))
        )
        coreMirror?.schedulePush()
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

    private static func recordIds(
        ofRemoved removed: Set<FavoriteEntry>,
        keepingAliasesOf remaining: Set<FavoriteEntry>
    ) -> Set<String> {
        let claimedAliases = legacyAliases(of: remaining)
        var ids: Set<String> = []
        for entry in removed {
            ids.insert(syncId(for: entry))
            guard let alias = legacyAlias(of: entry), !claimedAliases.contains(alias) else { continue }
            ids.insert(alias)
        }
        return ids
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
