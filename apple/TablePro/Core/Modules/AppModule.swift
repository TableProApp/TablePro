import Foundation

enum AppModule: String, CaseIterable, Sendable {
    case routineDebugger

    var title: String {
        switch self {
        case .routineDebugger: String(localized: "Routine Debugger")
        }
    }

    var summary: String {
        switch self {
        case .routineDebugger: String(localized: "Step through PL/pgSQL and PL/SQL routines with breakpoints.")
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .routineDebugger: false
        }
    }

    var defaultsKey: String {
        "com.TablePro.modules.\(rawValue).enabled"
    }

    static func enabledModules(in defaults: UserDefaults) -> Set<AppModule> {
        Set(allCases.filter { (defaults.object(forKey: $0.defaultsKey) as? Bool) ?? $0.defaultEnabled })
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
