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

    @Test("A fresh install has made no sync choice, syncs nothing and shares usage data")
    func freshInstall() {
        let preferences = OnboardingPreferences(defaults: defaults)

        #expect(preferences.syncChoice == nil)
        #expect(preferences.isCloudSyncEnabled == false)
        #expect(preferences.sharesUsageData)
        #expect(preferences.hasSeenWelcome == false)
    }

    @Test("A user who finished the old onboarding keeps syncing and gets the usage data default")
    func legacyUserMigrates() {
        defaults.set(true, forKey: OnboardingPreferences.hasSeenWelcomeKey)

        let preferences = OnboardingPreferences(defaults: defaults)

        #expect(preferences.hasSeenWelcome)
        #expect(preferences.syncChoice == true)
        #expect(preferences.sharesUsageData)
    }

    @Test("Usage data turned off in an older version stays off, and turned on stays on")
    func storedUsageDataChoiceWins() {
        defaults.set(false, forKey: AppPreferences.usageDataKey)
        #expect(OnboardingPreferences(defaults: defaults).sharesUsageData == false)

        defaults.set(true, forKey: AppPreferences.usageDataKey)
        #expect(OnboardingPreferences(defaults: defaults).sharesUsageData)
    }

    @Test("A legacy user who had turned sync off stays off")
    func legacyUserKeepsExplicitChoice() {
        defaults.set(true, forKey: OnboardingPreferences.hasSeenWelcomeKey)
        defaults.set(false, forKey: AppPreferences.cloudSyncEnabledKey)

        let preferences = OnboardingPreferences(defaults: defaults)

        #expect(preferences.syncChoice == false)
    }

    @Test("Choices and the last seen version survive a relaunch")
    func choicesPersist() {
        let preferences = OnboardingPreferences(defaults: defaults)
        preferences.setSyncChoice(true)
        preferences.setSharesUsageData(false)
        preferences.markWelcomeSeen()
        preferences.recordLaunch(version: "1.0")

        let reloaded = OnboardingPreferences(defaults: defaults)

        #expect(reloaded.syncChoice == true)
        #expect(reloaded.sharesUsageData == false)
        #expect(reloaded.hasSeenWelcome)
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
}
