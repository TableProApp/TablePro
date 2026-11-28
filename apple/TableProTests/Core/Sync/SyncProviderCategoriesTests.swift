@testable import TablePro
import TableProFFI
import Testing

struct SyncProviderCategoriesTests {
    @Test("TablePro Sync's own Passwords switch, on by default, decides whether envelopes sync, and iCloud Keychain's never does")
    func tableProSyncPasswordSwitchDecides() {
        var settings = SyncSettings.default
        settings.provider = .tableproSync

        #expect(SyncProviderCoordinator.categories(settings).passwords)

        settings.syncPasswords = true
        settings.syncPasswordsOnTableProSync = false

        #expect(!SyncProviderCoordinator.categories(settings).passwords)
    }

    @Test("A move from iCloud plans the passwords it will seal, with iCloud Keychain's switch off as it starts")
    func moveFromICloudPlansPasswords() {
        var settings = SyncSettings.default
        settings.enabled = true

        let config = SyncEngineHost.openConfig(provider: .icloud, settings: settings, icloudAccount: nil)

        #expect(!settings.syncsPasswords)
        #expect(config.categories.passwords)
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

    @Test("Sync opened for TablePro Sync tells the engine envelopes sync, as a later change does")
    func openOnTableProSyncCarriesPasswords() {
        var settings = SyncSettings.default
        settings.provider = .tableproSync
        settings.syncTableFavorites = false

        let config = SyncEngineHost.openConfig(provider: .tableproSync, settings: settings, icloudAccount: nil)

        #expect(config.provider == .tableproSync)
        #expect(config.categories.passwords)
        #expect(config.categories == SyncProviderCoordinator.categories(settings))
        #expect(config.categories.offKinds == ["favourite_table"])
    }

    @Test("SSH and credential profiles follow their switches, now that the core's library holds them")
    func profilesFollowTheirSwitches() {
        var settings = SyncSettings.default
        settings.syncSSHProfiles = true
        settings.syncCredentialProfiles = false

        let opened = SyncEngineHost.openConfig(provider: .icloud, settings: settings, icloudAccount: nil).categories
        let changed = SyncProviderCoordinator.categories(settings)

        #expect(opened.offKinds == ["credential_profile"])
        #expect(changed == opened)
    }
}
