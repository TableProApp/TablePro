import Foundation
import TableProPluginKit

struct RecentTableEntry: Codable, Equatable, Identifiable {
    let database: String?
    let schema: String?
    let name: String
    let isView: Bool

    /// The kind the object was opened as, as a `TableInfo.TableType` raw value.
    ///
    /// Nil for an entry written before the kind was recorded, and for an open whose caller knew
    /// only whether the object was a view. Kept as a string rather than the enum so an entry
    /// naming a kind this build has dropped decodes to nil instead of failing the whole file.
    let objectType: String?
    let openedAt: Date

    static func identityKey(schema: String?, name: String) -> String {
        "\(schema ?? "")\u{1}\(name)"
    }

    var scopeKey: String { database ?? "" }

    var identityKey: String { Self.identityKey(schema: schema, name: name) }

    var id: String { "\(scopeKey)\u{1}\(identityKey)" }

    var isUnqualified: Bool { schema?.isEmpty ?? true }

    /// An entry recorded before the schema was known names the same table as a qualified one, but
    /// opens that name in whichever schema is browsed when it is clicked. Only a qualified entry
    /// replaces an unqualified one: the reverse would trade a known schema for a guess.
    func supersedes(_ other: RecentTableEntry) -> Bool {
        !isUnqualified && other.isUnqualified && other.scopeKey == scopeKey && other.name == name
    }

    var tableInfo: TableInfo {
        TableInfo(name: name, type: resolvedType, rowCount: nil, schema: schema)
    }

    /// `isView` alone cannot say what an object is, only that it is not a table: a MariaDB sequence
    /// recorded through it came back as a view, so the Recent row offered Drop View and issued
    /// `DROP VIEW`, which fails with ERROR 4092 on the sequence the tree row drops correctly.
    /// An entry that predates the kind still resolves the way it always did.
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func entries(connectionId: UUID) -> [RecentTableEntry] {
        if let data = defaults.data(forKey: PreferenceKeys.recentTables(connectionId: connectionId).name) {
            return (try? JSONDecoder().decode([RecentTableEntry].self, from: data)) ?? []
        }
        return migrateLegacy(connectionId: connectionId)
    }

    private func migrateLegacy(connectionId: UUID) -> [RecentTableEntry] {
        let legacyKey = legacyKeyPrefix + connectionId.uuidString
        guard let data = defaults.data(forKey: legacyKey),
              let entries = try? JSONDecoder().decode([RecentTableEntry].self, from: data) else {
            return []
        }
        persist(entries, connectionId: connectionId)
        defaults.removeObject(forKey: legacyKey)
        return entries
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

    /// Drops the entries inside one schema, for a schema that no longer exists. Dropping the whole
    /// database's entries would take the sibling schemas with it, and leaving them is what made a
    /// Recent row open a tab whose query failed with "relation does not exist".
    @discardableResult
    func clear(connectionId: UUID, database: String?, schema: String) -> [RecentTableEntry] {
        let updated = entries(connectionId: connectionId).filter {
            !($0.database == database && $0.schema == schema)
        }
        persist(updated, connectionId: connectionId)
        return updated
    }

    /// A renamed table keeps its position rather than being dropped and re-added, which would look
    /// like the user had just opened it. Any stale entry already sitting on the new name is removed
    /// first: two entries with one id map to a single cached node and the outline draws neither.
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

    /// The entry takes the schema where it stands, keeping its position and the time it was opened,
    /// rather than being recorded again as if the user had just opened it.
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

    /// Reads, mutates and persists in one place, so a rename lands on disk whether or not the
    /// Recent section is on screen. The live list is empty while Show Recent Tables is off, and
    /// renaming only that left a dead entry to reappear under the old name when it came back on.
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
        defaults.removeObject(forKey: PreferenceKeys.recentTables(connectionId: connectionId).name)
        defaults.removeObject(forKey: legacyKeyPrefix + connectionId.uuidString)
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
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: PreferenceKeys.recentTables(connectionId: connectionId).name)
    }
}
