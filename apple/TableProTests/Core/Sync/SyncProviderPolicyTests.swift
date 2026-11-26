import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncProviderPolicyTests {
    @Test("No key leaves the person's switch as it is")
    func absentKeyKeepsTheSwitch() {
        let open = ManagedPolicySnapshot()

        #expect(SyncProviderPolicy.settledEnabled(true, under: open))
        #expect(!SyncProviderPolicy.settledEnabled(false, under: open))
        #expect(SyncProviderPolicy.iCloud(open) == .init(isAllowed: true, isLocked: false))
        #expect(SyncProviderPolicy.disableReason(open) == nil)
    }

    @Test("A profile that names only iCloud turns sync on as the person's switch would, and locks it")
    func forcedICloudTurnsSyncOn() {
        for list in [["icloud"], ["icloud", "tablepro-sync"]] {
            let forced = ManagedPolicySnapshot(personalSyncProvider: list)

            #expect(SyncProviderPolicy.settledEnabled(false, under: forced), "\(list)")
            #expect(SyncProviderPolicy.iCloud(forced) == .init(isAllowed: true, isLocked: true), "\(list)")
        }
    }

    @Test("iCloud taken away turns sync off and locks the switch, whichever key does it")
    func iCloudTakenAwayTurnsSyncOff() {
        let profiles = [
            ManagedPolicySnapshot(personalSyncProvider: ["off"]),
            ManagedPolicySnapshot(personalSyncProvider: ["tablepro-sync"]),
            ManagedPolicySnapshot(personalSyncProvider: []),
            ManagedPolicySnapshot(iCloudSyncAllowed: false),
            ManagedPolicySnapshot(personalSyncProvider: ["icloud"], iCloudSyncAllowed: false)
        ]
        for profile in profiles {
            #expect(!SyncProviderPolicy.settledEnabled(true, under: profile), "\(profile)")
            #expect(SyncProviderPolicy.iCloud(profile) == .init(isAllowed: false, isLocked: true), "\(profile)")
            #expect(SyncProviderPolicy.disableReason(profile) == .managedPolicy, "\(profile)")
        }
    }

    @Test("Off and iCloud both allowed leave the choice to the person")
    func bothAllowedLeaveTheChoice() {
        let both = ManagedPolicySnapshot(personalSyncProvider: ["off", "icloud"])

        #expect(SyncProviderPolicy.settledEnabled(true, under: both))
        #expect(!SyncProviderPolicy.settledEnabled(false, under: both))
        #expect(SyncProviderPolicy.iCloud(both) == .init(isAllowed: true, isLocked: false))
    }
}
