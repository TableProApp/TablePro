import Foundation
import Observation
import TableProFFI

@MainActor @Observable
final class OnboardingPreferences {
    // The old welcome page's key, read only to keep sync on for people who finished that onboarding.
    static let hasSeenWelcomeKey = "com.TablePro.hasCompletedOnboarding"
    // A new key, so someone who saw the old welcome and still has no connections gets the origin page once.
    static let hasSeenOriginKey = "com.TablePro.setupGuideSeen"
    static let lastSeenVersionKey = "com.TablePro.lastSeenAppVersion"

    @ObservationIgnored private let defaults: UserDefaults

    // Nil until the person chose a provider, or answered the first run's iCloud question.
    private(set) var providerChoice: SyncProviderTag?
    private(set) var usageDataChoice: Bool?
    private(set) var hasSeenOrigin: Bool
    private(set) var lastSeenVersion: String?
    // What the organization decides over the person's choices; their choices stay for when it lets go.
    private(set) var managed: ManagedAppConfiguration

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyState(in: defaults)
        providerChoice = AppPreferences.storedSyncProvider(in: defaults)
        usageDataChoice = defaults.object(forKey: AppPreferences.usageDataKey) as? Bool
        hasSeenOrigin = defaults.bool(forKey: Self.hasSeenOriginKey)
        lastSeenVersion = defaults.string(forKey: Self.lastSeenVersionKey)
        managed = ManagedAppConfiguration.current(defaults: defaults)
    }

    // Whether the first run's iCloud question was answered, either way.
    var syncChoice: Bool? {
        providerChoice.map { $0 != .off }
    }

    var syncProvider: SyncProviderTag {
        managed.settledProvider(providerChoice ?? .off)
    }

    var isCloudSyncEnabled: Bool {
        syncProvider == .icloud
    }

    var isUsageDataEnabled: Bool {
        usageDataChoice == true && managed.allowsUsageData
    }

    // An MDM changes the managed configuration while the app runs.
    func refreshManagedConfiguration() {
        let current = ManagedAppConfiguration.current(defaults: defaults)
        guard current != managed else { return }
        managed = current
    }

    func setSyncChoice(_ enabled: Bool) {
        setProvider(enabled ? .icloud : .off)
    }

    func setProvider(_ provider: SyncProviderTag) {
        providerChoice = provider
        AppPreferences.storeSyncProvider(provider, in: defaults)
    }

    func setUsageDataChoice(_ enabled: Bool) {
        usageDataChoice = enabled
        defaults.set(enabled, forKey: AppPreferences.usageDataKey)
    }

    func markOriginSeen() {
        guard !hasSeenOrigin else { return }
        hasSeenOrigin = true
        defaults.set(true, forKey: Self.hasSeenOriginKey)
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
