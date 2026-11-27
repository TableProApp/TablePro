import Foundation
import TableProFFI
@testable import TableProMobile
import Testing

@MainActor
struct SyncProviderChoiceTests {
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.SyncProvider.\(UUID().uuidString)"))
    }

    @Test("The previous release's iCloud switch becomes the provider, so an update keeps syncing as before")
    func earlierSwitchBecomesTheProvider() {
        defaults.set(true, forKey: AppPreferences.cloudSyncEnabledKey)
        #expect(OnboardingPreferences(defaults: defaults).syncProvider == .icloud)

        defaults.set(false, forKey: AppPreferences.cloudSyncEnabledKey)
        #expect(OnboardingPreferences(defaults: defaults).syncProvider == .off)
    }

    @Test("TablePro Sync is kept across a relaunch, and the previous release reads its iCloud switch as off")
    func tableProSyncLeavesTheEarlierSwitchOff() {
        let preferences = OnboardingPreferences(defaults: defaults)
        preferences.setProvider(.tableproSync)

        #expect(defaults.object(forKey: AppPreferences.cloudSyncEnabledKey) as? Bool == false)
        let relaunched = OnboardingPreferences(defaults: defaults)
        #expect(relaunched.providerChoice == .tableproSync)
        #expect(relaunched.syncProvider == .tableproSync)
        #expect(!relaunched.isCloudSyncEnabled)
        #expect(relaunched.syncChoice == true)
    }

    @Test("iCloud turned on or off in the previous release wins over the provider this build stored")
    func earlierReleaseChangeWins() {
        let preferences = OnboardingPreferences(defaults: defaults)
        preferences.setProvider(.tableproSync)
        defaults.set(true, forKey: AppPreferences.cloudSyncEnabledKey)
        #expect(OnboardingPreferences(defaults: defaults).syncProvider == .icloud)

        preferences.setProvider(.icloud)
        defaults.set(false, forKey: AppPreferences.cloudSyncEnabledKey)
        #expect(OnboardingPreferences(defaults: defaults).syncProvider == .off)
    }

    @Test("A required TablePro Sync leaves a device off until its upload runs, and keeps one that moved")
    func forcedTableProSyncWaitsForTheMove() {
        let managed = ManagedAppConfiguration(personalSyncProvider: ["tablepro-sync"])

        #expect(managed.settledProvider(.off) == .off)
        #expect(managed.settledProvider(.icloud) == .off)
        #expect(managed.settledProvider(.tableproSync) == .tableproSync)
        #expect(managed.locksSyncProvider)
        #expect(managed.locksICloudSync)
    }

    @Test("A required iCloud turns it on from Off, and leaves a device on TablePro Sync until the move back")
    func forcedICloudWaitsForTheMoveBack() {
        let managed = ManagedAppConfiguration(personalSyncProvider: ["icloud"])

        #expect(managed.settledProvider(.off) == .icloud)
        #expect(managed.settledProvider(.tableproSync) == .tableproSync)
    }

    @Test("No configuration leaves all three providers to the person, and the first run's iCloud question too")
    func unmanagedOffersEveryProvider() {
        let managed = ManagedAppConfiguration.unmanaged

        #expect(Set(managed.syncChoices.providers) == [.off, .icloud, .tableproSync])
        #expect(!managed.locksSyncProvider)
        #expect(!managed.locksICloudSync)
        #expect(managed.allowsTableProSync)
        #expect(managed.settledProvider(.tableproSync) == .tableproSync)
    }

    @Test("Every switch starts on but Passwords, and the engine is told none is off")
    func categoriesStartOn() {
        let categories = SyncCategories(defaults: defaults)

        #expect(categories == SyncCategories())
        #expect(categories.coreArgument == SyncCategoriesArg(offKinds: [], passwords: false))
    }

    @Test("A switch turned off names its kinds by the Mac's wire names, and passwords stop with connections")
    func categoriesNameTheirKinds() {
        var categories = SyncCategories(passwords: true)
        categories.connections = false
        categories.savedQueries = false
        categories.store(in: defaults)

        let read = SyncCategories(defaults: defaults)
        #expect(read == categories)
        #expect(read.coreArgument == SyncCategoriesArg(
            offKinds: ["connection", "connection_project", "saved_query", "saved_query_folder"],
            passwords: false
        ))
    }
}
