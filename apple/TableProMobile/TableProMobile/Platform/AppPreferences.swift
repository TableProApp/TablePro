import Foundation
import TableProFFI
import TableProModels

nonisolated enum AppPreferences {
    // The previous release's iCloud switch, still written for it: true only while the provider is iCloud.
    static let cloudSyncEnabledKey = "com.TablePro.settings.cloudSyncEnabled"
    static let syncProviderKey = "com.TablePro.settings.syncProvider"
    static let usageDataKey = "com.TablePro.settings.shareAnalytics"
    static let syncPasswordsKey = "com.TablePro.settings.syncPasswords"
    static let defaultPageSizeKey = "com.TablePro.settings.defaultPageSize"
    static let defaultSafeModeKey = "com.TablePro.settings.defaultSafeMode"
    static let hideQueryPreviewInActivityKey = "com.TablePro.settings.hideQueryPreviewInActivity"
    static let rowLayoutKey = "com.TablePro.settings.rowLayout"

    static let pageSizeOptions: [Int] = [50, 100, 200, 500]

    // The person's provider as the organization's values settle it.
    static var syncProvider: SyncProviderTag {
        ManagedAppConfiguration.current().settledProvider(storedSyncProvider(in: .standard) ?? .off)
    }

    static var isCloudSyncEnabled: Bool {
        syncProvider == .icloud
    }

    // Whether a password saved now goes to iCloud Keychain. On TablePro Sync the core seals each one for the server
    // and the Keychain item stays on this device, as on the Mac.
    static var syncsPasswords: Bool {
        syncProvider == .icloud && SyncCategories(defaults: .standard).syncsPasswords
    }

    // Nil until the person chose. The previous release writes only its iCloud switch, so a switch that no longer
    // matches the stored provider was turned there, and it wins.
    static func storedSyncProvider(in defaults: UserDefaults) -> SyncProviderTag? {
        let legacy = defaults.object(forKey: cloudSyncEnabledKey) as? Bool
        guard let stored = defaults.string(forKey: syncProviderKey).flatMap(SyncProviderTag.init(storedName:)) else {
            return legacy.map { $0 ? .icloud : .off }
        }
        if let legacy, legacy != (stored == .icloud) {
            return legacy ? .icloud : .off
        }
        return stored
    }

    static func storeSyncProvider(_ provider: SyncProviderTag, in defaults: UserDefaults) {
        defaults.set(provider.storedName, forKey: syncProviderKey)
        defaults.set(provider == .icloud, forKey: cloudSyncEnabledKey)
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

    static var hidesQueryPreviewInActivity: Bool {
        UserDefaults.standard.bool(forKey: hideQueryPreviewInActivityKey)
    }
}

extension SyncProviderTag {
    nonisolated var storedName: String {
        switch self {
        case .off: "off"
        case .icloud: "icloud"
        case .tableproSync: "tableproSync"
        }
    }

    nonisolated init?(storedName: String) {
        switch storedName {
        case "off": self = .off
        case "icloud": self = .icloud
        case "tableproSync": self = .tableproSync
        default: return nil
        }
    }
}
