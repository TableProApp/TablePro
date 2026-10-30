import Combine
import Foundation

// Per Mac: the keys live in the local defaults suite and no sync payload carries them.
@MainActor
final class AppModuleSettings: ObservableObject {
    static let shared = AppModuleSettings()

    @Published private(set) var enabledModules: Set<AppModule>

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        enabledModules = AppModule.enabledModules(in: defaults)
    }

    func isEnabled(_ module: AppModule) -> Bool {
        enabledModules.contains(module)
    }

    func setEnabled(_ enabled: Bool, for module: AppModule) {
        guard isEnabled(module) != enabled else { return }
        defaults.set(enabled, forKey: module.defaultsKey)
        if enabled {
            enabledModules.insert(module)
        } else {
            enabledModules.remove(module)
        }
        notificationCenter.post(name: .appModulesDidChange, object: module)
    }
}
