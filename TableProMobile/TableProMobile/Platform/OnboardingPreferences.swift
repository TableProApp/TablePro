import Foundation
import Observation

@MainActor @Observable
final class OnboardingPreferences {
    static let hasSeenWelcomeKey = "com.TablePro.hasCompletedOnboarding"
    static let lastSeenVersionKey = "com.TablePro.lastSeenAppVersion"

    @ObservationIgnored private let defaults: UserDefaults

    private(set) var syncChoice: Bool?
    private(set) var usageDataChoice: Bool?
    private(set) var hasSeenWelcome: Bool
    private(set) var lastSeenVersion: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyState(in: defaults)
        syncChoice = defaults.object(forKey: AppPreferences.cloudSyncEnabledKey) as? Bool
        usageDataChoice = defaults.object(forKey: AppPreferences.usageDataKey) as? Bool
        hasSeenWelcome = defaults.bool(forKey: Self.hasSeenWelcomeKey)
        lastSeenVersion = defaults.string(forKey: Self.lastSeenVersionKey)
    }

    var isCloudSyncEnabled: Bool {
        syncChoice == true
    }

    var isUsageDataEnabled: Bool {
        usageDataChoice == true
    }

    func setSyncChoice(_ enabled: Bool) {
        syncChoice = enabled
        defaults.set(enabled, forKey: AppPreferences.cloudSyncEnabledKey)
    }

    func setUsageDataChoice(_ enabled: Bool) {
        usageDataChoice = enabled
        defaults.set(enabled, forKey: AppPreferences.usageDataKey)
    }

    func markWelcomeSeen() {
        guard !hasSeenWelcome else { return }
        hasSeenWelcome = true
        defaults.set(true, forKey: Self.hasSeenWelcomeKey)
    }

    func recordLaunch(version: String) {
        guard lastSeenVersion != version else { return }
        lastSeenVersion = version
        defaults.set(version, forKey: Self.lastSeenVersionKey)
    }

    static func migrateLegacyState(in defaults: UserDefaults) {
        guard defaults.bool(forKey: hasSeenWelcomeKey),
              defaults.object(forKey: AppPreferences.cloudSyncEnabledKey) == nil else { return }
        defaults.set(true, forKey: AppPreferences.cloudSyncEnabledKey)
    }
}
