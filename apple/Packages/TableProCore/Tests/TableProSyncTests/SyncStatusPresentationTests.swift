import Foundation
import Testing

import TableProSyncTransport

struct SyncStatusPresentationTests {
    private static let everyBlocker: [SyncBlocker] = [
        .storageFull, .signedOut, .accountNotReady, .accountRestricted, .dataDeletedFromICloud,
        .appUpdateRequired, .unavailable
    ]

    private static let everyError: [SyncError] = everyBlocker.map { .blocked($0) } + [
        .offline, .busy, .recordsRejected(count: 3), .pullNotSaved, .unexpected
    ]

    @Test("Every error has a title of its own")
    func titlesAreDistinct() {
        let titles = Self.everyError.map { SyncStatusPresentation($0).title }
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    @Test("Try Again is offered only where another attempt can help")
    func tryAgainOnlyWhereItHelps() {
        let cannotHelp: [SyncError] = [
            .blocked(.accountRestricted), .blocked(.appUpdateRequired), .blocked(.unavailable),
            .blocked(.dataDeletedFromICloud)
        ]
        for error in Self.everyError {
            let offersRetry = SyncStatusPresentation(error).actions.contains(.tryAgain)
            #expect(offersRetry == !cannotHelp.contains(error), "\(error)")
        }
    }

    @Test("Each blocker offers the fix that clears it")
    func blockerActions() {
        #expect(SyncStatusPresentation(.blocked(.storageFull)).actions == [.manageStorage, .tryAgain])
        #expect(SyncStatusPresentation(.blocked(.signedOut)).actions == [.openAccountSettings, .tryAgain])
        #expect(SyncStatusPresentation(.blocked(.dataDeletedFromICloud)).actions == [.uploadAgain, .turnOffSync])
        #expect(SyncStatusPresentation(.blocked(.appUpdateRequired)).actions == [.checkForUpdates])
        #expect(SyncStatusPresentation(.blocked(.accountRestricted)).actions.isEmpty)
    }

    @Test("A synced or switched off state offers nothing and is no warning")
    func quietStates() {
        for status in [SyncStatus.idle, .syncing, .disabled(.userDisabled), .disabled(.licenseExpired)] {
            let presentation = SyncStatusPresentation(status: status)
            #expect(presentation.actions.isEmpty, "\(status)")
            #expect(!presentation.isWarning, "\(status)")
            #expect(presentation.blocker == nil, "\(status)")
        }
    }

    @Test("Every license reason reads as sync being off, which the license presentation explains")
    func disabledIsOneState() {
        let reasons: [DisableReason] = [.licenseRequired, .licenseExpired, .licenseUnverified, .userDisabled]
        let titles = Set(reasons.map { SyncStatusPresentation(status: .disabled($0)).title })
        #expect(titles.count == 1)
    }

    @Test("Only an account that cannot reach iCloud or a build that cannot sync draws the crossed out cloud")
    func symbols() {
        #expect(SyncStatusPresentation(.blocked(.signedOut)).symbolName == "icloud.slash")
        #expect(SyncStatusPresentation(.offline).symbolName == "icloud.slash")
        #expect(SyncStatusPresentation(.blocked(.accountRestricted)).symbolName == "xmark.icloud")
        #expect(SyncStatusPresentation(.blocked(.unavailable)).symbolName == "xmark.icloud")
        #expect(SyncStatusPresentation(.blocked(.accountNotReady)).symbolName == "exclamationmark.icloud")
        #expect(SyncStatusPresentation(status: .idle).symbolName == "checkmark.icloud")
    }

    @Test("Turning sync off names the feature it turns off")
    func turnOffSyncTitle() {
        #expect(SyncStatusAction.turnOffSync.title == "Turn Off iCloud Sync")
    }
}
