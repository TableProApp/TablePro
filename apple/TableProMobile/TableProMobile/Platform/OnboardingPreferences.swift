import Foundation
import Observation

@MainActor @Observable
final class OnboardingPreferences {
    static let hasSeenWelcomeKey = "com.TablePro.hasCompletedOnboarding"
    static let lastSeenVersionKey = "com.TablePro.lastSeenAppVersion"

    @ObservationIgnored private let defaults: UserDefaults

    private(set) var syncChoice: Bool?
    private(set) var sharesUsageData: Bool
    private(set) var hasSeenWelcome: Bool
    private(set) var lastSeenVersion: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyState(in: defaults)
        syncChoice = defaults.object(forKey: AppPreferences.cloudSyncEnabledKey) as? Bool
        // On unless turned off: a stored false, from Settings or an older build's first-run question, stays off.
        sharesUsageData = defaults.object(forKey: AppPreferences.usageDataKey) as? Bool ?? true
        hasSeenWelcome = defaults.bool(forKey: Self.hasSeenWelcomeKey)
        lastSeenVersion = defaults.string(forKey: Self.lastSeenVersionKey)
    }

    var isCloudSyncEnabled: Bool {
        syncChoice == true
    }

    func setSyncChoice(_ enabled: Bool) {
        syncChoice = enabled
        defaults.set(enabled, forKey: AppPreferences.cloudSyncEnabledKey)
    }

    func setSharesUsageData(_ enabled: Bool) {
        sharesUsageData = enabled
        defaults.set(enabled, forKey: AppPreferences.usageDataKey)
    }

    func markWelcomeSeen() {
        guard !hasSeenWelcome else { return }
        hasSeenWelcome = true
        defaults.set(true, forKey: Self.hasSeenWelcomeKey)
    }

    // An older build writes nothing, so going back to the newer one does not show its highlights again.
    func recordLaunch(version: String) {
        if let lastSeenVersion, !FirstRunPlan.isNewer(version, than: lastSeenVersion) { return }
        lastSeenVersion = version
        defaults.set(version, forKey: Self.lastSeenVersionKey)
    }

    static func migrateLegacyState(in defaults: UserDefaults) {
        guard defaults.bool(forKey: hasSeenWelcomeKey),
              defaults.object(forKey: AppPreferences.cloudSyncEnabledKey) == nil else { return }
        defaults.set(true, forKey: AppPreferences.cloudSyncEnabledKey)
    }
}
