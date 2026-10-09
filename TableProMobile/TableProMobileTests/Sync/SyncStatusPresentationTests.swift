import Foundation
@testable import TableProMobile
import TableProSyncTransport
import Testing

@Suite("Sync status presentation")
struct SyncStatusPresentationTests {
    private static let everyError: [SyncError] = [
        .blocked(.storageFull),
        .blocked(.signedOut),
        .blocked(.accountNotReady),
        .blocked(.accountRestricted),
        .blocked(.dataDeletedFromICloud),
        .blocked(.appUpdateRequired),
        .blocked(.unavailable),
        .offline,
        .busy,
        .recordsRejected(count: 3),
        .pullNotSaved,
        .unexpected,
    ]

    @Test("Each outcome has a title of its own, so an empty list never calls every problem the same thing")
    func titlesAreDistinct() {
        let titles = Self.everyError.map { SyncStatusPresentation($0).title }
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    @Test("Try Again is offered only where trying again can help")
    func tryAgainOnlyWhereItHelps() {
        let cannotHelp: [SyncError] = [
            .blocked(.accountRestricted),
            .blocked(.appUpdateRequired),
            .blocked(.unavailable),
            .blocked(.dataDeletedFromICloud),
        ]
        for error in Self.everyError {
            let offersRetry = SyncStatusPresentation(error).actions.contains(.tryAgain)
            #expect(offersRetry == !cannotHelp.contains(error), "\(error)")
        }
    }

    @Test("Deleted iCloud data offers to upload again or to turn sync off, and nothing else")
    func deletedDataActions() {
        #expect(SyncStatusPresentation(.blocked(.dataDeletedFromICloud)).actions == [.uploadAgain, .turnOffSync])
    }

    @Test("Only full storage gives a path in words, since no public link opens iCloud settings")
    func storageFullGuidance() {
        for error in Self.everyError {
            let guidance = SyncStatusPresentation(error).guidance
            #expect((guidance != nil) == (error == .blocked(.storageFull)), "\(error)")
        }
    }

    @Test("The number of refused changes is in the message, worded for one and for many")
    func rejectedCount() {
        let one = SyncStatusPresentation(.recordsRejected(count: 1)).message
        let three = SyncStatusPresentation(.recordsRejected(count: 3)).message
        #expect(one.contains("1"))
        #expect(three.contains("3"))
        #expect(one.replacingOccurrences(of: "1", with: "3") != three)
    }
}
