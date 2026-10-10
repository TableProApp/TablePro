import Foundation

@MainActor
final class DatabaseTreeFilterStorage {
    static let shared = DatabaseTreeFilterStorage()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
    }

    private func databasesKey(connectionId: UUID) -> String {
        "com.TablePro.treeDatabaseFilter.\(connectionId.uuidString).selected"
    }

    /// Keyed per database inside one value, because a schema name means something only inside the
    /// database that holds it. An engine with no database name keys its schemas under "".
    private func schemasKey(connectionId: UUID) -> String {
        "com.TablePro.treeSchemaFilter.\(connectionId.uuidString).selected"
    }

    func selectedDatabases(connectionId: UUID) -> Set<String> {
        guard let data = defaults.data(forKey: databasesKey(connectionId: connectionId)),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(names)
    }

    func setSelectedDatabases(_ databases: Set<String>, connectionId: UUID) {
        let key = databasesKey(connectionId: connectionId)
        guard !databases.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(databases.sorted()) else { return }
        defaults.set(data, forKey: key)
    }

    /// The raw selection, empty for no filter. A reader that decides what to read wants
    /// `SidebarSchemaFilter`, which sets aside names the sidebar would not show.
    func selectedSchemas(connectionId: UUID, database: String) -> Set<String> {
        allSelectedSchemas(connectionId: connectionId)[database] ?? []
    }

    func allSelectedSchemas(connectionId: UUID) -> [String: Set<String>] {
        guard let data = defaults.data(forKey: schemasKey(connectionId: connectionId)),
              let stored = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return stored.reduce(into: [:]) { result, entry in
            guard !entry.value.isEmpty else { return }
            result[entry.key] = Set(entry.value)
        }
    }

    func setSelectedSchemas(_ schemas: Set<String>, database: String, connectionId: UUID) {
        var all = allSelectedSchemas(connectionId: connectionId)
        all[database] = schemas.isEmpty ? nil : schemas
        setAllSelectedSchemas(all, connectionId: connectionId)
    }

    func setAllSelectedSchemas(_ selection: [String: Set<String>], connectionId: UUID) {
        let key = schemasKey(connectionId: connectionId)
        let stored = selection.reduce(into: [String: [String]]()) { result, entry in
            guard !entry.value.isEmpty else { return }
            result[entry.key] = entry.value.sorted()
        }
        guard !stored.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(stored) else { return }
        defaults.set(data, forKey: key)
    }

    func removeFilter(for connectionId: UUID) {
        defaults.removeObject(forKey: databasesKey(connectionId: connectionId))
        defaults.removeObject(forKey: schemasKey(connectionId: connectionId))
    }

    func removeFilters(for connectionIds: Set<UUID>) {
        for id in connectionIds { removeFilter(for: id) }
    }
}
