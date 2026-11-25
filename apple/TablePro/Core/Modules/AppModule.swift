import Foundation

enum AppModule: String, CaseIterable, Sendable {
    case routineDebugger
    case liveMessages
    case compareSync

    var title: String {
        switch self {
        case .routineDebugger: String(localized: "Routine Debugger")
        case .liveMessages: String(localized: "Live Messages")
        case .compareSync: String(localized: "Compare & Sync")
        }
    }

    var summary: String {
        switch self {
        case .routineDebugger: String(localized: "Step through PL/pgSQL and PL/SQL routines with breakpoints.")
        case .liveMessages: String(localized: "Watch PostgreSQL notifications, Redis channels and Kafka topics as messages arrive.")
        case .compareSync: String(localized: "Compare structure or data between two connections and generate the sync script.")
        }
    }

    // Shipped as core before it became a module, so a Mac that ran an earlier build keeps it on.
    var wasCore: Bool {
        switch self {
        case .compareSync: true
        case .routineDebugger, .liveMessages: false
        }
    }

    var defaultsKey: String {
        "com.TablePro.modules.\(rawValue).enabled"
    }

    var recordedDefaultKey: String {
        "com.TablePro.modules.\(rawValue).default"
    }

    func defaultEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: recordedDefaultKey)
    }

    static func enabledModules(in defaults: UserDefaults) -> Set<AppModule> {
        Set(allCases.filter { (defaults.object(forKey: $0.defaultsKey) as? Bool) ?? $0.defaultEnabled(in: defaults) })
    }

    // Once per Mac and module, at the first launch of a build that knows the module; later launches keep the answer.
    static func recordDefaults(in defaults: UserDefaults, isExistingInstall: Bool) {
        for module in allCases where module.wasCore && defaults.object(forKey: module.recordedDefaultKey) == nil {
            defaults.set(isExistingInstall, forKey: module.recordedDefaultKey)
        }
    }

    // For value types that cannot reach the main actor; reads the same keys `AppModuleSettings` writes.
    static func storedEnabledModules() -> Set<AppModule> {
        enabledModules(in: AppStorageEnvironment.shared.defaults)
    }
}

extension Notification.Name {
    // Posted after the new state is stored; `object` is the `AppModule` that changed.
    static let appModulesDidChange = Notification.Name("AppModulesDidChange")
}
