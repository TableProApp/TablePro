import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

struct SyncStatusPresentationTests {
    private static let everyBlocker: [SyncBlocker] = [
        .storageFull, .signedOut, .accountNotReady, .accountRestricted, .dataDeletedFromICloud,
        .appUpdateRequired, .unavailable
    ]

    private static let everyError: [SyncError] = everyBlocker.map { .blocked($0) } + [
        .offline, .busy, .recordsRejected(count: 1), .recordsRejected(count: 250), .pullNotSaved, .unexpected
    ]

    /// The reported bug: the pane printed CloudKit's own description, record id and all.
    @Test("Every error is worded in plain text, never with CloudKit's", arguments: everyError)
    func everyErrorIsWorded(_ error: SyncError) {
        let presentation = SyncStatusPresentation(status: .error(error))
        let texts = [presentation.indicatorLabel, presentation.statusTitle, presentation.helpText, presentation.message ?? ""]

        for text in texts {
            #expect(!text.isEmpty)
            #expect(!text.contains("CKRecordID"))
            #expect(!text.contains("CKError"))
        }
        #expect(presentation.isWarning)
    }

    @Test("Every blocker gets a notice at the top of the pane, and nothing else repeats it below")
    func blockersGetANotice() {
        for blocker in Self.everyBlocker {
            let presentation = SyncStatusPresentation(status: .error(.blocked(blocker)))
            #expect(presentation.notice != nil)
            #expect(presentation.statusDetail == nil)
        }
    }

    @Test("A failure that is not a blocker is explained under the status, with no notice")
    func lesserErrorsGetACaption() {
        let presentation = SyncStatusPresentation(status: .error(.offline))

        #expect(presentation.notice == nil)
        #expect(presentation.statusDetail == presentation.message)
    }

    @Test("Full storage offers to manage storage")
    func storageFullAction() {
        let notice = SyncStatusPresentation(status: .error(.blocked(.storageFull))).notice

        #expect(notice?.actions == [.manageStorage])
    }

    /// Uploading again is the person's call, so the pane offers it as a choice and hides Sync Now.
    @Test("Data removed from iCloud offers the choice and hides Sync Now")
    func removedDataOffersAChoice() {
        let presentation = SyncStatusPresentation(status: .error(.blocked(.dataDeletedFromICloud)))

        #expect(presentation.notice?.actions == [.uploadAgain, .turnOffSync])
        #expect(!presentation.offersSyncNow)
        #expect(SyncStatusPresentation(status: .error(.blocked(.storageFull))).offersSyncNow)
    }

    /// Compared with the count masked out, so the check holds in any language the catalog carries.
    @Test("One rejected change and several use different wording, each with its count")
    func rejectionCountAgrees() {
        let one = SyncStatusPresentation(status: .error(.recordsRejected(count: 1))).message ?? ""
        let several = SyncStatusPresentation(status: .error(.recordsRejected(count: 3))).message ?? ""

        #expect(one.contains("1"))
        #expect(several.contains("3"))
        #expect(one.replacingOccurrences(of: "1", with: "#") != several.replacingOccurrences(of: "3", with: "#"))
    }

    @Test("Sync the person turned off shows no indicator; a synced state is not a warning")
    func quietStates() {
        #expect(!SyncStatusPresentation(status: .disabled(.userDisabled)).showsIndicator)
        #expect(SyncStatusPresentation(status: .idle).showsIndicator)
        #expect(!SyncStatusPresentation(status: .idle).isWarning)
        #expect(SyncStatusPresentation(status: .idle).message == nil)
    }
}
