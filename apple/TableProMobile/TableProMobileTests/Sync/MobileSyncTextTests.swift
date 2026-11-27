import Foundation
import TableProFFI
@testable import TableProMobile
import Testing

struct MobileSyncTextTests {
    @Test("Every code a key or approval failure ends in reads as the keys not being held here")
    func keyCodesShareTheirWords() {
        let keys = MobileSyncText.message(forCode: "sync.device_not_approved")

        for code in ["sync.locked", "sync.not_allowed", "sync.device_removed", "keys.stale", "keys.sas_mismatch"] {
            #expect(MobileSyncText.message(forCode: code) == keys)
        }
    }

    @Test("An iCloud failure is worded as iCloud's, never as TablePro Sync's")
    func iCloudCodesAreICloudWords() {
        let fallback = MobileSyncText.message(forCode: "")

        for code in ["sync.icloud.no_account", "sync.icloud.quota_exceeded", "sync.icloud.network", "sync.icloud.other"] {
            #expect(MobileSyncText.message(forCode: code) != fallback)
        }
    }

    @Test("A code this build has no words for falls back to the general message")
    func unknownCodeFallsBack() {
        #expect(MobileSyncText.message(forCode: "sync.something_new") == MobileSyncText.message(forCode: ""))
    }

    @Test("A move error the app raises has its own words")
    func moveErrors() {
        let fallback = MobileSyncText.message(forCode: "")

        for error in [ProviderMoveError.notAllowed, .inProgress, .superseded, .serverRefusesPersonalSync, .signInChanged] {
            #expect(MobileSyncText.message(for: error) != fallback)
        }
        #expect(MobileSyncText.message(for: ProviderMoveError.engineUnavailable) == fallback)
    }
}
