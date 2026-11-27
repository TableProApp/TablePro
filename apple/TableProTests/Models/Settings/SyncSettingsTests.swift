import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

struct SyncSettingsTests {
    private static let everythingOn = SyncSettings(
        enabled: true,
        syncConnections: true,
        syncGroupsAndTags: true,
        syncSettings: true,
        syncPasswords: true,
        syncSSHProfiles: true,
        syncCredentialProfiles: true,
        syncTableFavorites: true,
        syncDatabaseFavorites: true,
        syncSQLFavorites: true,
        syncTableFolders: true
    )

    @Test("Turning Connections off turns Passwords off and leaves every other category")
    func connectionsOffClearsPasswords() {
        let result = Self.everythingOn.settingConnections(false)

        var expected = Self.everythingOn
        expected.syncConnections = false
        expected.syncPasswords = false
        #expect(result == expected)
        #expect(!result.syncsPasswords)
    }

    @Test("Turning Connections on keeps Passwords as it was", arguments: [true, false])
    func connectionsOnKeepsPasswords(passwords: Bool) {
        var settings = Self.everythingOn
        settings.syncConnections = false
        settings.syncPasswords = passwords
        settings.syncTableFolders = false

        let result = settings.settingConnections(true)

        var expected = settings
        expected.syncConnections = true
        #expect(result == expected)
    }

    @Test("Turning Connections off when it is already off changes nothing")
    func connectionsOffTwiceIsStable() {
        let once = SyncSettings.default.settingConnections(false)
        #expect(once.settingConnections(false) == once)
    }
}

struct SyncPaneLayoutTests {
    private static func layout(
        enabled: Bool,
        isLicensed: Bool,
        status: SyncStatus = .idle,
        isManaged: Bool = false,
        allowsICloud: Bool = true
    ) -> SyncPaneLayout {
        SyncPaneLayout(
            enabled: enabled,
            isLicensed: isLicensed,
            presentation: SyncStatusPresentation(status: status),
            isManaged: isManaged,
            allowsICloud: allowsICloud
        )
    }

    @Test("iCloud taken away by the organization: the switch is locked off, with no license gate, status or categories")
    func managedOff() {
        let layout = Self.layout(
            enabled: false, isLicensed: true, status: .disabled(.managedPolicy), isManaged: true, allowsICloud: false
        )
        #expect(layout.isToggleDisabled)
        #expect(layout.showsManagedNote)
        #expect(!layout.showsLicenseGate)
        #expect(!layout.showsStatus)
        #expect(!layout.showsLastSynced)
        #expect(!layout.showsCategories)
    }

    @Test("iCloud required by the organization: the switch is locked on and the license gate still shows without a license")
    func managedOn() {
        let licensed = Self.layout(enabled: true, isLicensed: true, isManaged: true)
        let unlicensed = Self.layout(enabled: true, isLicensed: false, status: .disabled(.licenseRequired), isManaged: true)

        #expect(licensed.isToggleDisabled && licensed.showsManagedNote)
        #expect(licensed.showsStatus && licensed.showsCategories)
        #expect(unlicensed.isToggleDisabled && unlicensed.showsLicenseGate)
    }

    @Test("Unlicensed and off: the switch is disabled and only the license gate shows")
    func unlicensedOff() {
        let layout = Self.layout(enabled: false, isLicensed: false, status: .disabled(.licenseRequired))
        #expect(layout.isToggleDisabled)
        #expect(layout.showsLicenseGate)
        #expect(!layout.showsStatus)
        #expect(!layout.showsLastSynced)
        #expect(!layout.showsCategories)
        #expect(layout.notice == nil)
    }

    @Test("A lapsed license leaves the switch enabled so sync can be turned off")
    func lapsedLicenseCanTurnOff() {
        let layout = Self.layout(enabled: true, isLicensed: false, status: .disabled(.licenseExpired))
        #expect(!layout.isToggleDisabled)
        #expect(layout.showsLicenseGate)
        #expect(!layout.showsStatus)
        #expect(!layout.showsLastSynced)
        #expect(!layout.showsCategories)
    }

    @Test("Licensed and off: the categories show so they can be chosen before the first upload")
    func licensedOffShowsCategories() {
        let layout = Self.layout(enabled: false, isLicensed: true, status: .disabled(.userDisabled))
        #expect(!layout.isToggleDisabled)
        #expect(!layout.showsLicenseGate)
        #expect(!layout.showsStatus)
        #expect(!layout.showsLastSynced)
        #expect(layout.showsCategories)
    }

    @Test("Licensed, on and idle: status, last synced with Sync Now, and the categories")
    func licensedOnIdle() {
        let layout = Self.layout(enabled: true, isLicensed: true, status: .idle)
        #expect(layout.notice == nil)
        #expect(layout.showsStatus)
        #expect(layout.showsLastSynced)
        #expect(layout.offersSyncNow)
        #expect(layout.showsCategories)
    }

    @Test(
        "A failure that a retry can clear keeps the Status row and Sync Now",
        arguments: [SyncError.offline, .busy, .recordsRejected(count: 2), .pullNotSaved, .unexpected]
    )
    func nonBlockerError(error: SyncError) {
        let layout = Self.layout(enabled: true, isLicensed: true, status: .error(error))
        #expect(layout.notice == nil)
        #expect(layout.showsStatus)
        #expect(layout.offersSyncNow)
    }

    @Test(
        "A blocker shows the notice instead of the Status row and drops Sync Now",
        arguments: [SyncBlocker.storageFull, .signedOut, .accountNotReady, .dataDeletedFromICloud, .appUpdateRequired]
    )
    func blockerShowsNotice(blocker: SyncBlocker) {
        let layout = Self.layout(enabled: true, isLicensed: true, status: .error(.blocked(blocker)))
        #expect(layout.notice != nil)
        #expect(!layout.showsStatus)
        #expect(layout.showsLastSynced)
        #expect(!layout.offersSyncNow)
        #expect(layout.showsCategories)
    }

    @Test("While syncing the Status row stays")
    func syncingKeepsStatus() {
        let layout = Self.layout(enabled: true, isLicensed: true, status: .syncing)
        #expect(layout.showsStatus)
        #expect(layout.offersSyncNow)
    }
}
