import Foundation
@testable import TableProMobile
import Testing

@MainActor
@Suite("Onboarding preferences")
struct OnboardingPreferencesTests {
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.Onboarding.\(UUID().uuidString)"))
    }

    @Test("A fresh install has made no choices and syncs nothing")
    func freshInstall() {
        let preferences = OnboardingPreferences(defaults: defaults)

        #expect(preferences.syncChoice == nil)
        #expect(preferences.usageDataChoice == nil)
        #expect(preferences.isCloudSyncEnabled == false)
        #expect(preferences.isUsageDataEnabled == false)
        #expect(preferences.hasSeenOrigin == false)
    }

    // Changed on purpose: the old welcome no longer counts as seeing the origin page, which an empty library shows once.
    @Test("A user who finished the old onboarding keeps syncing, is not assumed to consent, and has not seen the origin")
    func legacyUserMigrates() {
        defaults.set(true, forKey: OnboardingPreferences.hasSeenWelcomeKey)

        let preferences = OnboardingPreferences(defaults: defaults)

        #expect(preferences.hasSeenOrigin == false)
        #expect(preferences.syncChoice == true)
        #expect(preferences.usageDataChoice == nil)
    }

    @Test("A legacy user who had turned sync off stays off")
    func legacyUserKeepsExplicitChoice() {
        defaults.set(true, forKey: OnboardingPreferences.hasSeenWelcomeKey)
        defaults.set(false, forKey: AppPreferences.cloudSyncEnabledKey)

        let preferences = OnboardingPreferences(defaults: defaults)

        #expect(preferences.syncChoice == false)
    }

    @Test("The origin page is recorded under its own key and leaves the old one alone")
    func originHasItsOwnKey() {
        let preferences = OnboardingPreferences(defaults: defaults)
        preferences.markOriginSeen()

        #expect(defaults.bool(forKey: OnboardingPreferences.hasSeenOriginKey))
        #expect(defaults.object(forKey: OnboardingPreferences.hasSeenWelcomeKey) == nil)
        #expect(OnboardingPreferences(defaults: defaults).syncChoice == nil)
    }

    @Test("Choices and the last seen version survive a relaunch")
    func choicesPersist() {
        let preferences = OnboardingPreferences(defaults: defaults)
        preferences.setSyncChoice(true)
        preferences.setUsageDataChoice(false)
        preferences.markOriginSeen()
        preferences.recordLaunch(version: "1.0")

        let reloaded = OnboardingPreferences(defaults: defaults)

        #expect(reloaded.syncChoice == true)
        #expect(reloaded.usageDataChoice == false)
        #expect(reloaded.hasSeenOrigin)
        #expect(reloaded.lastSeenVersion == "1.0")
    }

    @Test("An older version records nothing, so the newer one stays recorded")
    func olderVersionKeepsNewerRecorded() {
        let preferences = OnboardingPreferences(defaults: defaults)
        preferences.recordLaunch(version: "1.1")

        preferences.recordLaunch(version: "1.0")

        #expect(preferences.lastSeenVersion == "1.1")
        #expect(OnboardingPreferences(defaults: defaults).lastSeenVersion == "1.1")
    }

    @Test("A newer version is recorded, compared as numbers")
    func newerVersionIsRecorded() {
        let preferences = OnboardingPreferences(defaults: defaults)
        preferences.recordLaunch(version: "1.9")

        preferences.recordLaunch(version: "1.10")

        #expect(OnboardingPreferences(defaults: defaults).lastSeenVersion == "1.10")
    }

    @Test("The organization's managed configuration turns iCloud sync and usage data off over the person's choice")
    func managedConfigurationWins() {
        defaults.set(true, forKey: AppPreferences.cloudSyncEnabledKey)
        defaults.set(true, forKey: AppPreferences.usageDataKey)
        defaults.set(
            ["ICloudSyncAllowed": false, "UsageDataAllowed": false],
            forKey: ManagedAppConfiguration.defaultsKey
        )

        let preferences = OnboardingPreferences(defaults: defaults)

        #expect(preferences.syncChoice == true)
        #expect(preferences.usageDataChoice == true)
        #expect(!preferences.isCloudSyncEnabled)
        #expect(!preferences.isUsageDataEnabled)
    }

    @Test("A configuration the MDM changes while the app runs is read again, and the person's choice comes back")
    func managedConfigurationRefreshes() {
        defaults.set(true, forKey: AppPreferences.cloudSyncEnabledKey)
        defaults.set(["ICloudSyncAllowed": false], forKey: ManagedAppConfiguration.defaultsKey)
        let preferences = OnboardingPreferences(defaults: defaults)

        defaults.removeObject(forKey: ManagedAppConfiguration.defaultsKey)
        preferences.refreshManagedConfiguration()

        #expect(preferences.managed == .unmanaged)
        #expect(preferences.isCloudSyncEnabled)
    }
}
