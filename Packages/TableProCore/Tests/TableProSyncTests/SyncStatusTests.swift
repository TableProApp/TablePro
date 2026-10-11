import Foundation
import Testing

import TableProSyncTransport

@Suite("Sync status")
struct SyncStatusTests {
    @Test("Only syncing reports itself as syncing")
    func onlySyncingIsSyncing() {
        #expect(SyncStatus.syncing.isSyncing)
        #expect(!SyncStatus.idle.isSyncing)
        #expect(!SyncStatus.error(.offline).isSyncing)
        #expect(!SyncStatus.disabled(.userDisabled).isSyncing)
    }

    @Test("Only disabled reports itself as not enabled", arguments: [
        DisableReason.licenseRequired,
        DisableReason.licenseExpired,
        DisableReason.licenseUnverified,
        DisableReason.userDisabled
    ])
    func disabledIsNotEnabled(_ reason: DisableReason) {
        #expect(!SyncStatus.disabled(reason).isEnabled)
    }

    /// Sync stays on while it waits for the account or the storage, so the triggers keep reaching
    /// the gate that decides what each one may do.
    @Test("A blocked or failed sync is still enabled")
    func blockedIsEnabled() {
        #expect(SyncStatus.idle.isEnabled)
        #expect(SyncStatus.syncing.isEnabled)
        #expect(SyncStatus.error(.offline).isEnabled)
        #expect(SyncStatus.error(.blocked(.storageFull)).isEnabled)
        #expect(SyncStatus.error(.blocked(.signedOut)).isEnabled)
    }

    @Test("A status exposes its error and nothing else does")
    func statusExposesItsError() {
        #expect(SyncStatus.error(.blocked(.storageFull)).error == .blocked(.storageFull))
        #expect(SyncStatus.idle.error == nil)
        #expect(SyncStatus.syncing.error == nil)
        #expect(SyncStatus.disabled(.userDisabled).error == nil)
    }

    @Test("Statuses with different reasons are not equal")
    func statusesCompareByPayload() {
        #expect(SyncStatus.disabled(.licenseExpired) != .disabled(.userDisabled))
        #expect(SyncStatus.error(.blocked(.storageFull)) != .error(.blocked(.signedOut)))
        #expect(SyncStatus.disabled(.userDisabled) == .disabled(.userDisabled))
        #expect(SyncStatus.disabled(.licenseUnverified) != .disabled(.licenseRequired))
    }
}
