import Foundation
import TableProPluginKit

struct RecentTableEntry: Codable, Equatable, Identifiable {
    let database: String?
    let schema: String?
    let name: String
    let isView: Bool
    let openedAt: Date

    static func identityKey(schema: String?, name: String) -> String {
        "\(schema ?? "")\u{1}\(name)"
    }

    var scopeKey: String { database ?? "" }

    var identityKey: String { Self.identityKey(schema: schema, name: name) }

    var id: String { "\(scopeKey)\u{1}\(identityKey)" }

    var tableInfo: TableInfo {
        TableInfo(name: name, type: isView ? .view : .table, rowCount: nil, schema: schema)
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
        connectionId: UUID, database: String?, schema: String?, name: String, isView: Bool, at date: Date = Date()
    ) -> [RecentTableEntry] {
        let entry = RecentTableEntry(database: database, schema: schema, name: name, isView: isView, openedAt: date)
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

    static func merged(_ entry: RecentTableEntry, into existing: [RecentTableEntry]) -> [RecentTableEntry] {
        var result = existing.filter { $0.id != entry.id }
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
