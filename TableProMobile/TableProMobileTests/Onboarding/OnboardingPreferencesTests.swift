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
        #expect(preferences.hasSeenWelcome == false)
    }

    @Test("A user who finished the old onboarding keeps syncing and is not assumed to consent")
    func legacyUserMigrates() {
        defaults.set(true, forKey: OnboardingPreferences.hasSeenWelcomeKey)

        let preferences = OnboardingPreferences(defaults: defaults)

        #expect(preferences.hasSeenWelcome)
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

    @Test("Choices and the last seen version survive a relaunch")
    func choicesPersist() {
        let preferences = OnboardingPreferences(defaults: defaults)
        preferences.setSyncChoice(true)
        preferences.setUsageDataChoice(false)
        preferences.markWelcomeSeen()
        preferences.recordLaunch(version: "1.0")

        let reloaded = OnboardingPreferences(defaults: defaults)

        #expect(reloaded.syncChoice == true)
        #expect(reloaded.usageDataChoice == false)
        #expect(reloaded.hasSeenWelcome)
        #expect(reloaded.lastSeenVersion == "1.0")
    }
}
