import Foundation
import TableProFFI
@testable import TableProMobile
import TableProSyncTransport
import Testing

private func status(_ phase: SyncPhaseTag, problem: String? = nil) -> SyncStatusInfo {
    SyncStatusInfo(
        provider: .tableproSync,
        phase: phase,
        lastPassMs: 1_000,
        problem: problem,
        waitingApprovals: 0,
        conflicts: 0,
        held: 0,
        queuedChanges: 0
    )
}

private func inputs(
    _ provider: SyncProviderTag,
    managed: ManagedAppConfiguration = .unmanaged,
    engine: SyncStatusInfo? = nil,
    scopes: [ScopeStatusInfo] = [],
    isSignedIn: Bool = true,
    hasICloudData: Bool = false
) -> MobileSyncInputs {
    MobileSyncInputs(
        provider: provider,
        choices: managed.syncChoices,
        iCloudStatus: .idle,
        engine: engine,
        scopes: scopes,
        isSignedIn: isSignedIn,
        hasICloudData: hasICloudData
    )
}

private func personal(sync: Bool? = nil, passwords: Bool? = nil, writable: Bool = true) -> ScopeStatusInfo {
    ScopeStatusInfo(scope: "personal", writable: writable, personalSync: sync, passwordSync: passwords, historySync: nil)
}

struct MobileSyncLayoutTests {
    @Test("Every provider is offered in a fixed order while nothing is managed")
    func everyProviderOffered() {
        let layout = MobileSyncLayout(inputs(.off))

        #expect(layout.options == [.off, .icloud, .tableproSync])
        #expect(!layout.isPickerLocked)
        #expect(layout.showsCategories)
        #expect(layout.serviceStatus == nil)
    }

    @Test("Each engine phase on TablePro Sync reads as its own status")
    func serviceStatuses() {
        let cases: [(SyncPhaseTag, MobileSyncServiceStatus)] = [
            (.idle, .upToDate),
            (.syncing, .syncing),
            (.waiting(retryInMs: 5_000), .waiting),
            (.pullOnly, .downloadOnly),
            (.unavailable, .unavailable),
        ]
        for (phase, expected) in cases {
            #expect(MobileSyncLayout(inputs(.tableproSync, engine: status(phase))).serviceStatus == expected)
        }
    }

    @Test("A device without the account's keys reads as needing approval, whatever the phase")
    func keysProblemNeedsApproval() {
        let layout = MobileSyncLayout(inputs(.tableproSync, engine: status(.waiting(retryInMs: 1_000), problem: "sync.device_not_approved")))

        #expect(layout.serviceStatus == .needsApproval)
        #expect(MobileSyncLayout.needsApproval("keys.stale"))
        #expect(!MobileSyncLayout.needsApproval("sync.network"))
    }

    @Test("Signed out on TablePro Sync shows the sign-in notice and no status")
    func signedOutOnTableProSync() {
        let layout = MobileSyncLayout(inputs(.tableproSync, engine: status(.idle), isSignedIn: false))

        #expect(layout.serviceNotice == .signedOut)
        #expect(layout.serviceStatus == nil)
        #expect(!layout.offersSyncNow)
    }

    @Test("A server that keeps no personal data takes TablePro Sync out as a new choice and says so on it")
    func serverRefusesPersonalData() {
        let refusing = [personal(sync: false)]

        #expect(!MobileSyncLayout(inputs(.off, scopes: refusing)).options.contains(.tableproSync))
        let on = MobileSyncLayout(inputs(.tableproSync, engine: status(.idle), scopes: refusing))
        #expect(on.options.contains(.tableproSync))
        #expect(on.serverPolicies == [.personalSyncOff])
        #expect(on.serviceStatus == nil)
        #expect(on.passwordsOffOnServer)
    }

    @Test("A read-only personal scope pauses uploads")
    func readOnlyScopePausesUploads() {
        let layout = MobileSyncLayout(inputs(.tableproSync, engine: status(.idle), scopes: [personal(writable: false)]))

        #expect(layout.serviceNotice == .pullOnly(selfHosted: false))
    }

    @Test("A required TablePro Sync on a device that is off asks for the upload review, and locks the picker")
    func forcedTableProSyncAsksForUpload() {
        let managed = ManagedAppConfiguration(personalSyncProvider: ["tablepro-sync"])
        let layout = MobileSyncLayout(inputs(.off, managed: managed))

        #expect(layout.serviceNotice == .awaitsUpload)
        #expect(layout.isPickerLocked)
        #expect(layout.forcedProvider == .tableproSync)
    }

    @Test("A required iCloud on a device on TablePro Sync asks for the move back")
    func forcedICloudAsksForMoveBack() {
        let managed = ManagedAppConfiguration(personalSyncProvider: ["icloud"])
        let layout = MobileSyncLayout(inputs(.tableproSync, managed: managed, engine: status(.idle)))

        #expect(layout.serviceNotice == .awaitsMoveBack)
    }

    @Test("iCloud data can be deleted only off iCloud, after this device synced with it, while iCloud is allowed")
    func iCloudDataDeletion() {
        #expect(MobileSyncLayout(inputs(.tableproSync, engine: status(.idle), hasICloudData: true)).offersICloudDataDeletion)
        #expect(!MobileSyncLayout(inputs(.icloud, hasICloudData: true)).offersICloudDataDeletion)
        #expect(!MobileSyncLayout(inputs(.off, hasICloudData: false)).offersICloudDataDeletion)
        let noICloud = ManagedAppConfiguration(iCloudSyncAllowed: false)
        #expect(!MobileSyncLayout(inputs(.off, managed: noICloud, hasICloudData: true)).offersICloudDataDeletion)
    }

    @Test("Another account waiting for a choice hides the status until the person picks")
    func newIdentityHidesStatus() {
        let layout = MobileSyncLayout(inputs(.tableproSync, engine: status(.newIdentity)))

        #expect(layout.asksNewIdentity)
        #expect(layout.serviceStatus == nil)
        #expect(!layout.showsLastSynced)
    }
}
