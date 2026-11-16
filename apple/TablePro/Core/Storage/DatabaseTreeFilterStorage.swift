import Foundation

@MainActor
final class DatabaseTreeFilterStorage {
    static let shared = DatabaseTreeFilterStorage()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
    }

    private func databasesKey(connectionId: UUID) -> JSONDefaultsKey<[String]> {
        JSONDefaultsKey("com.TablePro.treeDatabaseFilter.\(connectionId.uuidString).selected")
    }

    // Keyed per database, since a schema name means something only inside its database. No database name keys as "".
    private func schemasKey(connectionId: UUID) -> JSONDefaultsKey<[String: [String]]> {
        JSONDefaultsKey("com.TablePro.treeSchemaFilter.\(connectionId.uuidString).selected", coding: .sortedKeys)
    }

    func selectedDatabases(connectionId: UUID) -> Set<String> {
        Set(defaults.read(databasesKey(connectionId: connectionId)).value ?? [])
    }

    func setSelectedDatabases(_ databases: Set<String>, connectionId: UUID) {
        let key = databasesKey(connectionId: connectionId)
        guard !databases.isEmpty else {
            defaults.removeValue(for: key)
            return
        }
        try? defaults.write(databases.sorted(), to: key)
    }

    // The raw selection, empty for no filter. A reader deciding what to load wants `SidebarSchemaFilter`.
    func selectedSchemas(connectionId: UUID, database: String) -> Set<String> {
        allSelectedSchemas(connectionId: connectionId)[database] ?? []
    }

    func allSelectedSchemas(connectionId: UUID) -> [String: Set<String>] {
        let stored = defaults.read(schemasKey(connectionId: connectionId)).value ?? [:]
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
            defaults.removeValue(for: key)
            return
        }
        try? defaults.write(stored, to: key)
    }

    func removeFilter(for connectionId: UUID) {
        defaults.removeValue(for: databasesKey(connectionId: connectionId))
        defaults.removeValue(for: schemasKey(connectionId: connectionId))
    }

    func removeFilters(for connectionIds: Set<UUID>) {
        for id in connectionIds { removeFilter(for: id) }
    }
}
