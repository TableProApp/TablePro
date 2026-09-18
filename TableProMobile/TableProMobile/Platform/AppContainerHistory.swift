import Foundation

nonisolated struct AppContainerHistory: Sendable {
    static let live = AppContainerHistory()

    private static let key = "com.TablePro.appContainerIds"

    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    var containerIds: Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func record(_ containerId: String) {
        var ids = containerIds
        guard ids.insert(containerId).inserted else { return }
        defaults.set(ids.sorted(), forKey: Self.key)
    }
}
