import Foundation
import Testing

import TableProSyncTransport

@Suite("Sync status")
struct SyncStatusTests {
    @Test("Only syncing reports itself as syncing")
    func onlySyncingIsSyncing() {
        #expect(SyncStatus.syncing.isSyncing)
        #expect(!SyncStatus.idle.isSyncing)
        #expect(!SyncStatus.error(.tokenExpired).isSyncing)
        #expect(!SyncStatus.disabled(.noAccount).isSyncing)
    }

    @Test("Only disabled reports itself as not enabled", arguments: [
        DisableReason.noAccount,
        DisableReason.licenseRequired,
        DisableReason.licenseExpired,
        DisableReason.licenseUnverified,
        DisableReason.userDisabled
    ])
    func disabledIsNotEnabled(_ reason: DisableReason) {
        #expect(!SyncStatus.disabled(reason).isEnabled)
    }

    @Test("Every other case reports itself as enabled")
    func otherCasesAreEnabled() {
        #expect(SyncStatus.idle.isEnabled)
        #expect(SyncStatus.syncing.isEnabled)
        #expect(SyncStatus.error(.networkUnavailable).isEnabled)
    }

    @Test("A status carries its error so the UI can describe it")
    func statusCarriesItsError() {
        guard case .error(let error) = SyncStatus.error(.quotaExceeded) else {
            Issue.record("Expected an error status")
            return
        }
        #expect(error == .quotaExceeded)
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test("Statuses with different reasons are not equal")
    func statusesCompareByPayload() {
        #expect(SyncStatus.disabled(.noAccount) != .disabled(.userDisabled))
        #expect(SyncStatus.error(.tokenExpired) != .error(.networkUnavailable))
        #expect(SyncStatus.disabled(.noAccount) == .disabled(.noAccount))
        #expect(SyncStatus.disabled(.licenseUnverified) != .disabled(.licenseRequired))
    }
}
