import Foundation
import TableProPluginKit

struct RecentTableEntry: Codable, Equatable, Identifiable {
    let database: String?
    let schema: String?
    let name: String
    let isView: Bool

    // A raw value, not the enum, so a kind this build has dropped reads as nil instead of failing the whole list.
    let objectType: String?
    let openedAt: Date

    static func identityKey(schema: String?, name: String) -> String {
        "\(schema ?? "")\u{1}\(name)"
    }

    var scopeKey: String { database ?? "" }

    var identityKey: String { Self.identityKey(schema: schema, name: name) }

    var id: String { "\(scopeKey)\u{1}\(identityKey)" }

    var isUnqualified: Bool { schema?.isEmpty ?? true }

    // Only a qualified entry replaces an unqualified one: the reverse would trade a known schema for a guess.
    func supersedes(_ other: RecentTableEntry) -> Bool {
        !isUnqualified && other.isUnqualified && other.scopeKey == scopeKey && other.name == name
    }

    var tableInfo: TableInfo {
        TableInfo(name: name, type: resolvedType, rowCount: nil, schema: schema)
    }

    // `isView` alone turned a MariaDB sequence into a view, so its Recent row issued a failing `DROP VIEW`.
    private var resolvedType: TableInfo.TableType {
        if let objectType, let type = TableInfo.TableType(rawValue: objectType) { return type }
        return isView ? .view : .table
    }
}

struct RecentTableRow: Identifiable {
    let table: TableInfo

    var id: String { "recent\u{1}\(table.id)" }
}

@MainActor
final class RecentTablesStore {
    static let shared = RecentTablesStore()

    static let perDatabaseCap = 10

    private let defaults: UserDefaults
    private let legacyKeyPrefix = "RecentTables.v1."

    init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
    }

    func entries(connectionId: UUID) -> [RecentTableEntry] {
        switch defaults.read(PreferenceKeys.recentTables(connectionId: connectionId)) {
        case .missing: return migrateLegacy(connectionId: connectionId)
        case .value(let entries): return entries
        case .unreadable: return []
        }
    }

    private func migrateLegacy(connectionId: UUID) -> [RecentTableEntry] {
        let key = legacyKey(for: connectionId)
        guard let entries = defaults.read(key).value else { return [] }
        persist(entries, connectionId: connectionId)
        defaults.removeValue(for: key)
        return entries
    }

    private func legacyKey(for connectionId: UUID) -> JSONDefaultsKey<[RecentTableEntry]> {
        JSONDefaultsKey(legacyKeyPrefix + connectionId.uuidString)
    }

    @discardableResult
    func record(
        connectionId: UUID,
        database: String?,
        schema: String?,
        name: String,
        isView: Bool,
        objectType: TableInfo.TableType?,
        at date: Date = Date()
    ) -> [RecentTableEntry] {
        let entry = RecentTableEntry(
            database: database, schema: schema, name: name,
            isView: isView, objectType: objectType?.rawValue, openedAt: date
        )
        let updated = Self.merged(entry, into: entries(connectionId: connectionId))
        persist(updated, connectionId: connectionId)
        return updated
    }

    @discardableResult
    func remove(connectionId: UUID, entry: RecentTableEntry) -> [RecentTableEntry] {
        let updated = entries(connectionId: connectionId).filter { $0.id != entry.id }
        persist(updated, connectionId: connectionId)
        return updated
    }

    @discardableResult
    func clear(connectionId: UUID, database: String?) -> [RecentTableEntry] {
        let scope = database ?? ""
        let updated = entries(connectionId: connectionId).filter { $0.scopeKey != scope }
        persist(updated, connectionId: connectionId)
        return updated
    }

    // For a schema that no longer exists, whose entries otherwise open tabs failing with "relation does not exist".
    @discardableResult
    func clear(connectionId: UUID, database: String?, schema: String) -> [RecentTableEntry] {
        let updated = entries(connectionId: connectionId).filter {
            !($0.database == database && $0.schema == schema)
        }
        persist(updated, connectionId: connectionId)
        return updated
    }

    // A stale entry on the new name goes first: two entries with one id share a node and the outline draws neither.
    func rename(connectionId: UUID, entry: RecentTableEntry, to newName: String) -> [RecentTableEntry] {
        mutate(connectionId: connectionId) { entries in
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
            let existing = entries[index]
            let renamed = RecentTableEntry(
                database: existing.database, schema: existing.schema, name: newName,
                isView: existing.isView, objectType: existing.objectType, openedAt: existing.openedAt
            )
            entries.removeAll { $0.id == renamed.id }
            guard let insertion = entries.firstIndex(where: { $0.id == existing.id }) else { return false }
            entries[insertion] = renamed
            return true
        }
    }

    func renameDatabase(connectionId: UUID, from oldName: String, to newName: String) -> [RecentTableEntry] {
        mutate(connectionId: connectionId) { entries in
            guard entries.contains(where: { $0.database == oldName }) else { return false }
            entries = entries.map { entry in
                guard entry.database == oldName else { return entry }
                return RecentTableEntry(
                    database: newName, schema: entry.schema, name: entry.name,
                    isView: entry.isView, objectType: entry.objectType, openedAt: entry.openedAt
                )
            }
            return Self.deduplicate(&entries)
        }
    }

    func renameSchema(
        connectionId: UUID,
        database: String?,
        from oldName: String,
        to newName: String
    ) -> [RecentTableEntry] {
        mutate(connectionId: connectionId) { entries in
            guard entries.contains(where: { $0.database == database && $0.schema == oldName }) else { return false }
            entries = entries.map { entry in
                guard entry.database == database, entry.schema == oldName else { return entry }
                return RecentTableEntry(
                    database: entry.database, schema: newName, name: entry.name,
                    isView: entry.isView, objectType: entry.objectType, openedAt: entry.openedAt
                )
            }
            return Self.deduplicate(&entries)
        }
    }

    func resolveSchema(
        connectionId: UUID,
        database: String?,
        name: String,
        to schema: String
    ) -> [RecentTableEntry] {
        mutate(connectionId: connectionId) { entries in
            guard let index = entries.firstIndex(where: {
                $0.database == database && $0.name == name && $0.isUnqualified
            }) else { return false }
            let existing = entries[index]
            entries[index] = RecentTableEntry(
                database: existing.database, schema: schema, name: existing.name,
                isView: existing.isView, objectType: existing.objectType, openedAt: existing.openedAt
            )
            return Self.deduplicate(&entries)
        }
    }

    // Persists whether or not Recent is on screen, so a rename made while it is off leaves no dead entry.
    private func mutate(
        connectionId: UUID,
        _ body: (inout [RecentTableEntry]) -> Bool
    ) -> [RecentTableEntry] {
        var entries = self.entries(connectionId: connectionId)
        guard body(&entries) else { return entries }
        persist(entries, connectionId: connectionId)
        return entries
    }

    @discardableResult
    private static func deduplicate(_ entries: inout [RecentTableEntry]) -> Bool {
        var seen = Set<String>()
        entries = entries.filter { seen.insert($0.id).inserted }
        return true
    }

    func removeEntries(for connectionId: UUID) {
        defaults.removeValue(for: PreferenceKeys.recentTables(connectionId: connectionId))
        defaults.removeValue(for: legacyKey(for: connectionId))
    }

    static func merged(_ entry: RecentTableEntry, into existing: [RecentTableEntry]) -> [RecentTableEntry] {
        var result = existing.filter { $0.id != entry.id && !entry.supersedes($0) }
        result.insert(entry, at: 0)
        var perScopeCount: [String: Int] = [:]
        return result.filter { candidate in
            let count = perScopeCount[candidate.scopeKey, default: 0]
            guard count < perDatabaseCap else { return false }
            perScopeCount[candidate.scopeKey] = count + 1
            return true
        }
    }

    private func persist(_ entries: [RecentTableEntry], connectionId: UUID) {
        try? defaults.write(entries, to: PreferenceKeys.recentTables(connectionId: connectionId))
    }
}
