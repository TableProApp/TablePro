import Foundation

struct PrivilegeExpansionStore {
    private static let prefix = "com.TablePro.usersRoles.expanded."

    private let defaults: UserDefaults
    private let key: String

    init(connectionId: UUID, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = Self.prefix + connectionId.uuidString
    }

    func load() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    func save(_ keys: [String]) {
        guard !keys.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(keys, forKey: key)
    }

    func insert(_ persistentKey: String) {
        var keys = load()
        guard !keys.contains(persistentKey) else { return }
        keys.append(persistentKey)
        save(keys)
    }

    func remove(_ persistentKey: String) {
        let keys = load().filter { $0 != persistentKey && !$0.hasPrefix(persistentKey + "/") }
        save(keys)
    }
}
