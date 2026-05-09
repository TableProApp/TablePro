import Foundation
import TableProModels

enum AppPreferences {
    static let cloudSyncEnabledKey = "com.TablePro.settings.cloudSyncEnabled"
    static let defaultPageSizeKey = "com.TablePro.settings.defaultPageSize"
    static let defaultSafeModeKey = "com.TablePro.settings.defaultSafeMode"

    static let pageSizeOptions: [Int] = [50, 100, 200, 500]

    static var isCloudSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: cloudSyncEnabledKey) as? Bool ?? true
    }

    static var defaultPageSize: Int {
        guard let stored = UserDefaults.standard.object(forKey: defaultPageSizeKey) as? Int,
              pageSizeOptions.contains(stored) else { return 100 }
        return stored
    }

    static var defaultSafeMode: SafeModeLevel {
        guard let raw = UserDefaults.standard.string(forKey: defaultSafeModeKey),
              let level = SafeModeLevel(rawValue: raw) else { return .off }
        return level
    }
}
