import Foundation

/// Device-local, per-connection filter for the tree sidebar's database list.
/// Holds an enable toggle and the set of database names shown when enabled.
@MainActor
final class DatabaseTreeFilterStorage {
    static let shared = DatabaseTreeFilterStorage()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func enabledKey(connectionId: UUID) -> String {
        "com.TablePro.treeDatabaseFilter.\(connectionId.uuidString).enabled"
    }

    private func databasesKey(connectionId: UUID) -> String {
        "com.TablePro.treeDatabaseFilter.\(connectionId.uuidString).selected"
    }

    func isEnabled(connectionId: UUID) -> Bool {
        defaults.bool(forKey: enabledKey(connectionId: connectionId))
    }

    func setEnabled(_ enabled: Bool, connectionId: UUID) {
        defaults.set(enabled, forKey: enabledKey(connectionId: connectionId))
    }

    func selectedDatabases(connectionId: UUID) -> Set<String> {
        guard let data = defaults.data(forKey: databasesKey(connectionId: connectionId)),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(names)
    }

    func setSelectedDatabases(_ databases: Set<String>, connectionId: UUID) {
        guard let data = try? JSONEncoder().encode(Array(databases).sorted()) else { return }
        defaults.set(data, forKey: databasesKey(connectionId: connectionId))
    }

    func removeFilter(for connectionId: UUID) {
        defaults.removeObject(forKey: enabledKey(connectionId: connectionId))
        defaults.removeObject(forKey: databasesKey(connectionId: connectionId))
    }

    func removeFilters(for connectionIds: Set<UUID>) {
        for id in connectionIds { removeFilter(for: id) }
    }
}
