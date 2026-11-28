import Foundation
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import Testing

struct SyncPaneLayoutTests {
    private static let everyProvider = PersonalSyncChoices(providers: [.off, .icloud, .tableproSync], forced: nil, locked: false)

    private static func engine(
        _ provider: SyncProviderTag?,
        _ phase: SyncPhaseTag = .idle,
        problem: String? = nil,
        lastSyncedMs: Int64? = nil
    ) -> SyncStatusInfo {
        SyncStatusInfo(
            provider: provider,
            phase: phase,
            lastPassMs: nil,
            lastSyncedMs: lastSyncedMs,
            problem: problem,
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
        serverLicense: AccountServerLicense? = nil,
        waitingApprovals: Int = 0
    ) -> SyncPaneLayout {
        SyncPaneLayout(SyncPaneInputs(
            provider: provider,
            choices: choices,
            iCloudAccess: iCloud,
            serviceAccess: service,
            iCloudStatus: status,
            engine: engine,
            serverLicense: serverLicense,
            waitingApprovals: waitingApprovals
        ))
    }

    // MARK: - Changes waiting for approval

    @Test("iCloud up to date with changes waiting: the status row names the count and offers Review")
    func approvalsReplaceUpToDateOnICloud() {
        let layout = Self.layout(provider: .iCloud, status: .idle, engine: Self.engine(.icloud), waitingApprovals: 3)
        #expect(layout.showsICloudStatus)
        #expect(layout.approvalsInStatus)
        #expect(layout.offersReview)
        #expect(!layout.showsApprovalsRow)
        #expect(layout.waitingApprovals == 3)
    }

    @Test("TablePro Sync up to date with changes waiting: the status row names the count, never Up to Date")
    func approvalsReplaceUpToDateOnService() {
        let layout = Self.layout(provider: .tableproSync, engine: Self.engine(.tableproSync, .needsApproval), waitingApprovals: 1)
        #expect(layout.serviceStatus == .upToDate)
        #expect(layout.approvalsInStatus)
        #expect(layout.offersReview)
    }

    @Test("A pass or a problem keeps its own status line, and Review stays beside it")
    func approvalsBesideAnotherStatus() {
        let syncing = Self.layout(provider: .iCloud, status: .syncing, engine: Self.engine(.icloud), waitingApprovals: 2)
        #expect(!syncing.approvalsInStatus)
        #expect(syncing.offersReview)
        #expect(!syncing.showsApprovalsRow)

        let waiting = Self.layout(provider: .tableproSync, engine: Self.engine(.tableproSync, .waiting(retryInMs: 1_000)), waitingApprovals: 2)
        #expect(waiting.serviceStatus == .waiting)
        #expect(!waiting.approvalsInStatus)
        #expect(waiting.offersReview)
    }

    @Test("Sync off with Team Library values waiting: the count gets a row of its own")
    func approvalsRowWithSyncOff() {
        let layout = Self.layout(provider: .off, engine: Self.engine(.off, .needsApproval), waitingApprovals: 4)
        #expect(!layout.showsICloudStatus)
        #expect(layout.serviceStatus == nil)
        #expect(layout.showsApprovalsRow)
        #expect(layout.offersReview)
    }

    @Test("Nothing waiting: no Review and no approvals row")
    func noApprovals() {
        let layout = Self.layout(provider: .iCloud, status: .idle, engine: Self.engine(.icloud))
        #expect(!layout.approvalsInStatus)
        #expect(!layout.offersReview)
        #expect(!layout.showsApprovalsRow)
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

    @Test("The engine's pull-only phase on iCloud says uploads are paused, not that sync failed")
    func iCloudPullOnly() {
        let layout = Self.layout(provider: .iCloud, status: .error(.unexpected), engine: Self.engine(.icloud, .pullOnly))
        #expect(layout.serviceNotice == .pullOnly(selfHosted: false))
        #expect(layout.iCloudNotice == nil)
        #expect(!layout.showsICloudStatus)
        #expect(!layout.offersSyncNow)
    }

    @Test("Each engine phase maps to the pane's own state on TablePro Sync")
    func servicePhases() {
        let phases: [(SyncPhaseTag, SyncServiceStatus?)] = [
            (.idle, .upToDate), (.syncing, .syncing), (.waiting(retryInMs: 500), .waiting), (.pullOnly, .downloadOnly),
            (.off, .off), (.unavailable, .unavailable), (.zoneRemoved, .unavailable), (.newIdentity, nil),
            (.needsApproval, .upToDate),
        ]
        for (phase, status) in phases {
            let layout = Self.layout(provider: .tableproSync, engine: Self.engine(.tableproSync, phase))
            #expect(layout.serviceStatus == status, "\(phase)")
            #expect(layout.asksNewIdentity == (phase == .newIdentity), "\(phase)")
        }
    }

    @Test("A keychain that has not answered yet reads as a wait on TablePro Sync, whatever the phase says")
    func keychainWaitIsARetry() {
        for problem in ["sync.state.anchor_unsettled", "sync.device_store.locked"] {
            let layout = Self.layout(provider: .tableproSync, engine: Self.engine(.tableproSync, .unavailable, problem: problem))
            #expect(layout.serviceStatus == .waiting, "\(problem)")
        }
        let failed = Self.layout(provider: .tableproSync, engine: Self.engine(.tableproSync, .unavailable, problem: "sync.server"))
        #expect(failed.serviceStatus == .unavailable)
    }

    @Test("A pass that failed never reads Up to Date: one the core tries again waits, any other is unavailable and says why")
    func failedPassIsNotUpToDate() {
        let retried = ["sync.network", "sync.server", "sync.rate_limited", "sync.state.busy", "account.unreachable"]
        for problem in retried {
            let layout = Self.layout(provider: .tableproSync, engine: Self.engine(.tableproSync, problem: problem))
            #expect(layout.serviceStatus == .waiting, "\(problem)")
            #expect(layout.serviceProblem == nil, "\(problem)")
        }
        for problem in ["sync.signed_out", "sync.device_not_approved", "sync.feature_required", "sync.state.io"] {
            let layout = Self.layout(provider: .tableproSync, engine: Self.engine(.tableproSync, problem: problem))
            #expect(layout.serviceStatus == .unavailable, "\(problem)")
            #expect(layout.serviceProblem == ProviderMoves.message(forCode: problem), "\(problem)")
        }
        for problem in ["sync.cancelled", "sync.adapter.unreadable"] {
            let layout = Self.layout(provider: .tableproSync, engine: Self.engine(.tableproSync, problem: problem))
            #expect(layout.serviceStatus == .upToDate, "\(problem)")
        }
    }

    @Test("The prompt for another account says how many changes here were never uploaded")
    func newIdentityMessageCountsUnsent() {
        let plain = SyncNewIdentityNotice.message(nil)
        #expect(SyncNewIdentityNotice.message(NewIdentityPlanInfo(unsent: 0, account: "acct")) == plain)
        let counted = SyncNewIdentityNotice.message(NewIdentityPlanInfo(unsent: 3, account: "acct"))
        #expect(counted.hasPrefix(plain))
        #expect(counted.contains("3"))
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

    @Test("A forced TablePro Sync leaves the Mac off until the person reviews its first upload")
    func forcedServiceAwaitsUpload() {
        let layout = Self.layout(provider: .off, choices: Self.choices([.tableproSync]), engine: Self.engine(.off))
        #expect(layout.serviceNotice == .awaitsUpload)
        #expect(layout.serviceStatus == nil)
        #expect(layout.licenseGate == nil)
        #expect(layout.managedNote == .forced(.tableproSync))
        #expect(layout.options == [.off, .tableproSync])
        #expect(layout.isPickerLocked)
    }

    @Test("A forced iCloud on a Mac on TablePro Sync asks for the move back")
    func forcedICloudAwaitsMoveBack() {
        let layout = Self.layout(provider: .tableproSync, choices: Self.choices([.icloud]), engine: Self.engine(.tableproSync))
        #expect(layout.serviceNotice == .awaitsMoveBack)
        #expect(layout.options == [.iCloud, .tableproSync])
        #expect(layout.isPickerLocked)
    }

    @Test("A forced TablePro Sync on a Mac that is not signed in says why it stays off")
    func forcedServiceSignedOut() {
        let layout = Self.layout(provider: .off, choices: Self.choices([.tableproSync]), service: .signedOut)
        #expect(layout.serviceNotice == nil)
        #expect(layout.licenseGate == .serviceSync)
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

    // E2E F21: relaunched with the server out of reach, a Mac said "Sync Is Unavailable" and "Last synced: Never".
    @Test("A launch with the server out of reach that never synced waits to retry and has never synced")
    func launchOfflineNeverSynced() {
        let engine = Self.engine(.tableproSync, .waiting(retryInMs: 2_000), problem: "sync.network")
        let layout = Self.layout(provider: .tableproSync, engine: engine)
        #expect(layout.serviceStatus == .waiting)
        #expect(layout.showsLastSynced)
        #expect(layout.lastSynced == nil)
    }

    @Test("A launch with the server out of reach after a sync waits to retry and shows the last sync the core kept")
    func launchOfflineAfterASync() {
        let engine = Self.engine(.tableproSync, .waiting(retryInMs: 2_000), problem: "sync.network", lastSyncedMs: 1_764_000_000_000)
        let layout = Self.layout(provider: .tableproSync, engine: engine)
        #expect(layout.serviceStatus == .waiting)
        #expect(layout.lastSynced == Date(timeIntervalSince1970: 1_764_000_000))
    }

    @Test("Last synced follows the provider: the core's on TablePro Sync, the coordinator's on iCloud, none while off")
    func lastSyncedFollowsTheProvider() {
        var inputs = SyncPaneInputs(
            provider: .tableproSync,
            choices: Self.everyProvider,
            iCloudAccess: .available,
            serviceAccess: .available,
            iCloudStatus: .idle,
            engine: Self.engine(.tableproSync, lastSyncedMs: 1_764_000_000_000),
            serverLicense: nil
        )
        inputs.iCloudLastSynced = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(SyncPaneLayout(inputs).lastSynced == Date(timeIntervalSince1970: 1_764_000_000))
        inputs.provider = .iCloud
        #expect(SyncPaneLayout(inputs).lastSynced == Date(timeIntervalSince1970: 1_700_000_000))
        inputs.provider = .off
        #expect(SyncPaneLayout(inputs).lastSynced == nil)
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

    // MARK: - The server's switches

    private static func scope(
        _ name: String,
        writable: Bool = true,
        personal: Bool? = true,
        passwords: Bool? = nil,
        history: Bool? = nil
    ) -> ScopeStatusInfo {
        ScopeStatusInfo(scope: name, writable: writable, personalSync: personal, passwordSync: passwords, historySync: history)
    }

    private static func layout(provider: SyncProviderSetting, scopes: [ScopeStatusInfo]) -> SyncPaneLayout {
        SyncPaneLayout(SyncPaneInputs(
            provider: provider,
            choices: everyProvider,
            iCloudAccess: .available,
            serviceAccess: .available,
            iCloudStatus: .disabled(.userDisabled),
            engine: engine(.tableproSync),
            serverLicense: nil,
            scopes: scopes
        ))
    }

    @Test("A server that keeps no personal data says so, stops the status, and leaves the provider where it is")
    func personalSyncOff() {
        let layout = Self.layout(provider: .tableproSync, scopes: [Self.scope("personal", personal: false)])
        #expect(layout.serverPolicies == [.personalSyncOff])
        #expect(layout.serviceStatus == nil)
        #expect(layout.serviceNotice == nil)
        #expect(layout.passwordsOffOnServer)
        #expect(layout.options.contains(.tableproSync))
    }

    @Test("A server that keeps no personal data is no new choice for a Mac on another provider")
    func personalSyncOffTakesTheChoiceAway() {
        let layout = Self.layout(provider: .iCloud, scopes: [Self.scope("personal", personal: false)])
        #expect(!layout.options.contains(.tableproSync))
        #expect(layout.serverPolicies.isEmpty)
    }

    @Test("Passwords and history off on the server are each said, and the status goes on")
    func passwordsAndHistoryOff() {
        let layout = Self.layout(provider: .tableproSync, scopes: [
            Self.scope("personal", passwords: false),
            Self.scope("history", history: false),
            Self.scope("team_A1", personal: nil, passwords: false),
        ])
        #expect(layout.serverPolicies == [.passwordsOff, .historyOff])
        #expect(layout.passwordsOffOnServer)
        #expect(layout.serviceStatus == .upToDate)
    }

    @Test("Every switch on, or no scopes read yet, says nothing")
    func switchesOnSayNothing() {
        for scopes in [[], [Self.scope("personal", passwords: true), Self.scope("history", history: true)]] {
            let layout = Self.layout(provider: .tableproSync, scopes: scopes)
            #expect(layout.serverPolicies.isEmpty)
            #expect(!layout.passwordsOffOnServer)
        }
    }

    @Test("A personal scope the server keeps read-only is pull-only, as past grace")
    func readOnlyScopeIsPullOnly() {
        let layout = Self.layout(provider: .tableproSync, scopes: [Self.scope("personal", writable: false)])
        #expect(layout.serviceNotice == .pullOnly(selfHosted: false))
    }

    @Test("The server's switches say nothing for a Mac on iCloud or off")
    func switchesOnlyForTableProSync() {
        for provider in [SyncProviderSetting.iCloud, .off] {
            let layout = Self.layout(provider: provider, scopes: [Self.scope("personal", passwords: false)])
            #expect(layout.serverPolicies.isEmpty)
        }
    }
}
