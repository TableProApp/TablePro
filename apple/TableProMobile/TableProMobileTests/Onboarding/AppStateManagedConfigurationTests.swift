import Foundation
@testable import TableProMobile
import TableProSyncTransport
import Testing

@MainActor
struct AppStateManagedConfigurationTests {
    @Test("ICloudSyncAllowed turned off stops iCloud sync at once, and lifting it brings the person's choice back")
    func iCloudFollowsTheManagedConfiguration() throws {
        let fixture = try AppStateFixture()
        fixture.defaults.set(true, forKey: AppPreferences.cloudSyncEnabledKey)
        let state = fixture.makeState(syncEnabled: true)

        fixture.defaults.set(["ICloudSyncAllowed": false], forKey: ManagedAppConfiguration.defaultsKey)
        state.refreshManagedConfiguration()

        #expect(!state.onboarding.isCloudSyncEnabled)
        #expect(state.syncCoordinator.status == .disabled(.userDisabled))
        #expect(state.onboarding.syncChoice == true)

        fixture.defaults.removeObject(forKey: ManagedAppConfiguration.defaultsKey)
        state.refreshManagedConfiguration()

        #expect(state.onboarding.isCloudSyncEnabled)
        #expect(state.syncCoordinator.status != .disabled(.userDisabled))
    }

    @Test("A welcome that skipped the iCloud question for the organization leaves sync off once the policy goes")
    func skippedQuestionIsNoConsent() throws {
        let fixture = try AppStateFixture()
        fixture.defaults.set(["ICloudSyncAllowed": false], forKey: ManagedAppConfiguration.defaultsKey)
        let state = fixture.makeState(syncEnabled: false)

        state.finishFirstRun(pages: [.welcome, .usageData])
        fixture.defaults.removeObject(forKey: ManagedAppConfiguration.defaultsKey)
        let relaunched = OnboardingPreferences(defaults: fixture.defaults)

        #expect(relaunched.syncChoice == false)
        #expect(!relaunched.isCloudSyncEnabled)
    }
}
