@testable import TablePro
import TableProFFI
import Testing

struct SyncProviderCategoriesTests {
    @Test("With iCloud off, as TablePro Sync leaves it, the password switch still decides whether envelopes sync")
    func passwordSwitchHoldsOnTableProSync() {
        var settings = SyncSettings.default
        settings.enabled = false
        settings.syncPasswords = true

        #expect(SyncProviderCoordinator.categories(settings).passwords)

        settings.syncPasswords = false

        #expect(!SyncProviderCoordinator.categories(settings).passwords)
    }

    @Test("A connection project goes with the connections")
    func connectionProjectFollowsConnections() {
        let settings = SyncSettings.default

        #expect(!SyncProviderCoordinator.categories(settings).offKinds.contains(SyncProviderCoordinator.connectionProjectKind))
        #expect(SyncProviderCoordinator.categories(settings.settingConnections(false)).offKinds.contains("connection_project"))
    }

    @Test("The settings switch turns off the Mac's settings kind")
    func settingsSwitchTurnsOffTheSettingsKind() {
        var settings = SyncSettings.default
        settings.syncSettings = false

        #expect(SyncProviderCoordinator.categories(settings).offKinds == ["macos_settings"])
    }
}
