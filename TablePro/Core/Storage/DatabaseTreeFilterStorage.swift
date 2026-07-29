import Foundation

@MainActor
final class DatabaseTreeFilterStorage {
    static let shared = DatabaseTreeFilterStorage()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func databasesKey(connectionId: UUID) -> String {
        "com.TablePro.treeDatabaseFilter.\(connectionId.uuidString).selected"
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

    func removeFilter(for connectionId: UUID) {
        defaults.removeObject(forKey: databasesKey(connectionId: connectionId))
    }

    func removeFilters(for connectionIds: Set<UUID>) {
        for id in connectionIds { removeFilter(for: id) }
    }
}
