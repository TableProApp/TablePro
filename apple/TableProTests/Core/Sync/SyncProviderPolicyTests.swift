import Foundation
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import Testing

@MainActor
struct SyncProviderPolicyTests {
    @Test("No key leaves the person's provider as it is", arguments: SyncProviderSetting.allCases)
    func absentKeyKeepsTheProvider(provider: SyncProviderSetting) {
        let open = ManagedPolicySnapshot()

        #expect(SyncProviderPolicy.settledProvider(provider, under: open) == provider)
        #expect(SyncProviderPolicy.iCloud(open) == .init(isAllowed: true, isLocked: false))
        #expect(SyncProviderPolicy.disableReason(open) == nil)
        #expect(SyncProviderPolicy.choices(open).providers == [.off, .icloud, .tableproSync])
    }

    @Test("A profile that names only iCloud turns iCloud on as the person would, and locks it")
    func forcedICloudTurnsSyncOn() {
        let forced = ManagedPolicySnapshot(personalSyncProvider: ["icloud"])

        for provider in SyncProviderSetting.allCases {
            #expect(SyncProviderPolicy.settledProvider(provider, under: forced) == .iCloud, "\(provider)")
        }
        #expect(SyncProviderPolicy.iCloud(forced) == .init(isAllowed: true, isLocked: true))
    }

    @Test("A profile that names only TablePro Sync stops iCloud and keeps a Mac that has not moved off until it does")
    func forcedTableProSync() {
        let forced = ManagedPolicySnapshot(personalSyncProvider: ["tablepro-sync"])

        #expect(SyncProviderPolicy.settledProvider(.iCloud, under: forced) == .off)
        #expect(SyncProviderPolicy.settledProvider(.off, under: forced) == .off)
        #expect(SyncProviderPolicy.settledProvider(.tableproSync, under: forced) == .tableproSync)
        #expect(SyncProviderPolicy.iCloud(forced) == .init(isAllowed: false, isLocked: true))
        #expect(SyncProviderPolicy.disableReason(forced) == .managedPolicy)
    }

    @Test("iCloud taken away turns it off and leaves TablePro Sync where the profile allows it")
    func iCloudTakenAway() {
        let profiles = [
            ManagedPolicySnapshot(personalSyncProvider: ["off"]),
            ManagedPolicySnapshot(personalSyncProvider: []),
            ManagedPolicySnapshot(iCloudSyncAllowed: false),
            ManagedPolicySnapshot(personalSyncProvider: ["icloud"], iCloudSyncAllowed: false),
            ManagedPolicySnapshot(personalSyncProvider: ["off", "tablepro-sync"])
        ]
        for profile in profiles {
            #expect(SyncProviderPolicy.settledProvider(.iCloud, under: profile) == .off, "\(profile)")
            #expect(!SyncProviderPolicy.iCloud(profile).isAllowed, "\(profile)")
            #expect(SyncProviderPolicy.disableReason(profile) == .managedPolicy, "\(profile)")
        }
        let iCloudOff = ManagedPolicySnapshot(iCloudSyncAllowed: false)
        #expect(SyncProviderPolicy.settledProvider(.tableproSync, under: iCloudOff) == .tableproSync)
        #expect(SyncProviderPolicy.iCloud(iCloudOff) == .init(isAllowed: false, isLocked: false))
    }

    @Test("TablePro Sync taken away turns it off, and never moves the Mac to iCloud")
    func tableProSyncTakenAway() {
        let both = ManagedPolicySnapshot(personalSyncProvider: ["off", "icloud"])

        #expect(SyncProviderPolicy.settledProvider(.tableproSync, under: both) == .off)
        #expect(SyncProviderPolicy.settledProvider(.iCloud, under: both) == .iCloud)
        #expect(SyncProviderPolicy.iCloud(both) == .init(isAllowed: true, isLocked: false))
    }

    @Test("A profile whose list is empty leaves no provider, whatever was chosen")
    func emptyListLeavesNone() {
        let none = ManagedPolicySnapshot(personalSyncProvider: [])

        #expect(SyncProviderPolicy.choices(none).providers.isEmpty)
        #expect(SyncProviderPolicy.choices(none).locked)
        #expect(SyncProviderPolicy.settledProvider(.tableproSync, under: none) == .off)
    }
}
