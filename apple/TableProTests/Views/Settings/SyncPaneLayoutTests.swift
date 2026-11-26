import Foundation
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import Testing

struct SyncPaneLayoutTests {
    private static let everyProvider = PersonalSyncChoices(providers: [.off, .icloud, .tableproSync], forced: nil, locked: false)

    private static func engine(_ provider: SyncProviderTag?, _ phase: SyncPhaseTag = .idle) -> SyncStatusInfo {
        SyncStatusInfo(
            provider: provider,
            phase: phase,
            lastPassMs: nil,
            problem: nil,
            waitingApprovals: 0,
            conflicts: 0,
            held: 0,
            queuedChanges: 0
        )
    }

    private static func choices(_ providers: [SyncProviderTag]) -> PersonalSyncChoices {
        PersonalSyncChoices(providers: providers, forced: providers.count == 1 ? providers[0] : nil, locked: providers.count <= 1)
    }

    private static func layout(
        provider: SyncProviderSetting,
        choices: PersonalSyncChoices = everyProvider,
        iCloud: ProFeatureAccess = .available,
        service: ProFeatureAccess = .available,
        status: SyncStatus = .idle,
        engine: SyncStatusInfo? = nil,
        serverLicense: AccountServerLicense? = nil
    ) -> SyncPaneLayout {
        SyncPaneLayout(SyncPaneInputs(
            provider: provider,
            choices: choices,
            iCloudAccess: iCloud,
            serviceAccess: service,
            iCloudStatus: status,
            engine: engine,
            serverLicense: serverLicense
        ))
    }

    // MARK: - The picker and the organization

    @Test("With no profile the picker offers Off, iCloud and TablePro Sync, unlocked")
    func everyProviderOffered() {
        let layout = Self.layout(provider: .off)
        #expect(layout.options == [.off, .iCloud, .tableproSync])
        #expect(!layout.isPickerLocked)
        #expect(layout.managedNote == nil)
    }

    @Test("iCloud taken away by the organization: Off is locked, with no license gate, status or categories")
    func managedOff() {
        let layout = Self.layout(provider: .off, choices: Self.choices([.off]), status: .disabled(.managedPolicy))
        #expect(layout.options == [.off])
        #expect(layout.isPickerLocked)
        #expect(layout.managedNote == .forced(.off))
        #expect(layout.licenseGate == nil)
        #expect(!layout.showsICloudStatus)
        #expect(!layout.showsLastSynced)
        #expect(!layout.showsCategories)
    }

    @Test("A profile that leaves no provider locks the picker and says so")
    func noProviderLeft() {
        let layout = Self.layout(provider: .off, choices: Self.choices([]))
        #expect(layout.isPickerLocked)
        #expect(layout.managedNote == .noProvider)
        #expect(layout.options == [.off])
        #expect(!layout.showsCategories)
    }

    @Test("iCloud required by the organization: locked on, and the license gate still shows without a license")
    func managedICloud() {
        let licensed = Self.layout(provider: .iCloud, choices: Self.choices([.icloud]))
        let unlicensed = Self.layout(
            provider: .iCloud, choices: Self.choices([.icloud]), iCloud: .notIncluded, status: .disabled(.licenseRequired)
        )

        #expect(licensed.isPickerLocked && licensed.managedNote == .forced(.iCloud))
        #expect(licensed.showsICloudStatus && licensed.showsCategories)
        #expect(unlicensed.isPickerLocked && unlicensed.licenseGate == .iCloudSync)
    }

    @Test("Two providers left by the profile leave the choice to the person")
    func twoProvidersLeft() {
        let layout = Self.layout(
            provider: .iCloud,
            choices: PersonalSyncChoices(providers: [.icloud, .tableproSync], forced: nil, locked: false)
        )
        #expect(layout.options == [.iCloud, .tableproSync])
        #expect(!layout.isPickerLocked)
    }

    // MARK: - iCloud

    @Test("Unlicensed iCloud shows only the license gate, with nothing live")
    func unlicensedICloud() {
        let layout = Self.layout(provider: .iCloud, iCloud: .expired, status: .disabled(.licenseExpired))
        #expect(layout.licenseGate == .iCloudSync)
        #expect(!layout.showsICloudStatus)
        #expect(!layout.showsLastSynced)
        #expect(layout.iCloudNotice == nil)
    }

    @Test("Off with a licensed provider: the categories show so they can be chosen before the first upload")
    func offShowsCategories() {
        let layout = Self.layout(provider: .off, status: .disabled(.userDisabled))
        #expect(layout.licenseGate == nil)
        #expect(!layout.showsICloudStatus)
        #expect(!layout.showsLastSynced)
        #expect(layout.showsCategories)
    }

    @Test("Off with no provider licensed shows no categories")
    func offUnlicensed() {
        let layout = Self.layout(provider: .off, iCloud: .notIncluded, service: .signedOut)
        #expect(!layout.showsCategories)
    }

    @Test("iCloud on and idle: status, last synced with Sync Now, and the categories")
    func iCloudIdle() {
        let layout = Self.layout(provider: .iCloud)
        #expect(layout.iCloudNotice == nil)
        #expect(layout.showsICloudStatus)
        #expect(layout.showsLastSynced)
        #expect(layout.offersSyncNow)
        #expect(layout.showsCategories)
        #expect(layout.serviceStatus == nil)
    }

    @Test(
        "A failure that a retry can clear keeps the Status row and Sync Now",
        arguments: [SyncError.offline, .busy, .recordsRejected(count: 2), .pullNotSaved, .unexpected]
    )
    func nonBlockerError(error: SyncError) {
        let layout = Self.layout(provider: .iCloud, status: .error(error))
        #expect(layout.iCloudNotice == nil)
        #expect(layout.showsICloudStatus)
        #expect(layout.offersSyncNow)
    }

    @Test(
        "A blocker shows the notice instead of the Status row and drops Sync Now",
        arguments: [SyncBlocker.storageFull, .signedOut, .accountNotReady, .dataDeletedFromICloud, .appUpdateRequired]
    )
    func blockerShowsNotice(blocker: SyncBlocker) {
        let layout = Self.layout(provider: .iCloud, status: .error(.blocked(blocker)))
        #expect(layout.iCloudNotice != nil)
        #expect(!layout.showsICloudStatus)
        #expect(layout.showsLastSynced)
        #expect(!layout.offersSyncNow)
        #expect(layout.showsCategories)
    }

    @Test("While iCloud syncs the Status row stays")
    func iCloudSyncingKeepsStatus() {
        let layout = Self.layout(provider: .iCloud, status: .syncing)
        #expect(layout.showsICloudStatus)
        #expect(layout.offersSyncNow)
    }

    @Test("An iCloud account switch asks Move my data or Start empty in place of the status")
    func iCloudNewIdentity() {
        let layout = Self.layout(provider: .iCloud, status: .error(.unexpected), engine: Self.engine(.icloud, .newIdentity))
        #expect(layout.asksNewIdentity)
        #expect(!layout.showsICloudStatus)
        #expect(!layout.offersSyncNow)
    }

    // MARK: - TablePro Sync

    @Test("TablePro Sync signed out shows its license gate and nothing live")
    func serviceSignedOut() {
        let layout = Self.layout(provider: .tableproSync, service: .signedOut, engine: Self.engine(.off))
        #expect(layout.licenseGate == .serviceSync)
        #expect(layout.serviceNotice == nil)
        #expect(layout.serviceStatus == nil)
        #expect(!layout.showsLastSynced)
    }

    @Test("A forced TablePro Sync waits for the person's upload review before anything goes up")
    func forcedServiceAwaitsUpload() {
        let layout = Self.layout(
            provider: .tableproSync, choices: Self.choices([.tableproSync]), engine: Self.engine(.off)
        )
        #expect(layout.serviceNotice == .awaitsUpload(forced: true))
        #expect(layout.serviceStatus == nil)
        #expect(layout.managedNote == .forced(.tableproSync))
    }

    @Test("A move that did not finish asks again, and the engine not yet open reads the same")
    func unfinishedMoveAsksAgain() {
        #expect(Self.layout(provider: .tableproSync, engine: Self.engine(.icloud)).serviceNotice == .awaitsUpload(forced: false))
        #expect(Self.layout(provider: .tableproSync, engine: nil).serviceNotice == .awaitsUpload(forced: false))
    }

    @Test("On TablePro Sync and idle: status, last synced with Sync Now, and no notice")
    func serviceIdle() {
        let layout = Self.layout(provider: .tableproSync, engine: Self.engine(.tableproSync))
        #expect(layout.serviceNotice == nil)
        #expect(layout.serviceStatus == .upToDate)
        #expect(layout.showsLastSynced)
        #expect(layout.offersSyncNow)
        #expect(layout.licenseGate == nil)
        #expect(!layout.showsICloudStatus)
    }

    @Test("Past grace on a company server: uploads paused, downloads go on, the license gate offers the way back")
    func servicePastGraceSelfHosted() {
        let license = AccountServerLicense(seats: 5, isTrial: false, expiresAt: .distantPast, graceEndsAt: .distantPast, state: .lapsed)
        let layout = Self.layout(
            provider: .tableproSync, service: .expired, engine: Self.engine(.tableproSync, .pullOnly), serverLicense: license
        )
        #expect(layout.serviceNotice == .pullOnly(selfHosted: true))
        #expect(layout.serviceStatus == .downloadOnly)
        #expect(layout.showsLastSynced)
        #expect(layout.licenseGate == .serviceSync)
    }

    @Test("A lapsed plan reads pull-only from the engine even while the feature still answers")
    func servicePullOnlyFromTheEngine() {
        let layout = Self.layout(provider: .tableproSync, engine: Self.engine(.tableproSync, .pullOnly))
        #expect(layout.serviceNotice == .pullOnly(selfHosted: false))
    }

    @Test("Inside a company server's grace TablePro Sync still syncs, and says until when")
    func serviceInGrace() {
        let ends = Date(timeIntervalSince1970: 1_800_000_000)
        let license = AccountServerLicense(seats: 5, isTrial: false, expiresAt: .distantPast, graceEndsAt: ends, state: .grace)
        let layout = Self.layout(provider: .tableproSync, engine: Self.engine(.tableproSync), serverLicense: license)
        #expect(layout.serviceNotice == .grace(until: ends))
        #expect(layout.serviceStatus == .upToDate)
    }

    @Test("While TablePro Sync syncs there is no Sync Now")
    func serviceSyncing() {
        let layout = Self.layout(provider: .tableproSync, engine: Self.engine(.tableproSync, .syncing))
        #expect(layout.serviceStatus == .syncing)
        #expect(!layout.offersSyncNow)
    }

    @Test("Another TablePro account asks Move my data or Start empty in place of the status")
    func serviceNewIdentity() {
        let layout = Self.layout(provider: .tableproSync, engine: Self.engine(.tableproSync, .newIdentity))
        #expect(layout.asksNewIdentity)
        #expect(layout.serviceStatus == nil)
    }

    @Test("The iCloud data row shows only when the moves offer it")
    func iCloudDataRow() {
        var inputs = SyncPaneInputs(
            provider: .tableproSync,
            choices: Self.everyProvider,
            iCloudAccess: .available,
            serviceAccess: .available,
            iCloudStatus: .disabled(.userDisabled),
            engine: Self.engine(.tableproSync),
            serverLicense: nil
        )
        #expect(!SyncPaneLayout(inputs).offersICloudDataDeletion)
        inputs.offersICloudDataDeletion = true
        #expect(SyncPaneLayout(inputs).offersICloudDataDeletion)
    }
}
