import CloudKit
import Foundation
import Testing

@testable import TableProSyncTransport

struct PullAcknowledgementTests {
    private static let zoneID = CKRecordZone.ID(zoneName: "TableProSync", ownerName: CKCurrentUserDefaultName)

    private static func id(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private static func page(
        from start: String?,
        changed: [String] = [],
        deleted: [String] = [],
        unread: [String] = []
    ) -> PullAcknowledgement.Page<String> {
        PullAcknowledgement.Page(
            startToken: start,
            changed: Set(changed.map { id($0) }),
            deleted: Set(deleted.map { id($0) }),
            unread: unread.map { id($0) }
        )
    }

    @Test("A pull that read every record acknowledges its final token")
    func everyRecordRead() {
        let settled = PullAcknowledgement.settle(
            [Self.page(from: "t0", changed: ["a"]), Self.page(from: "t1", deleted: ["b"])],
            finalToken: "t2"
        )

        #expect(settled.token == "t2")
        #expect(settled.unread.isEmpty)
    }

    @Test("A record CloudKit could not read holds the token at the start of its page")
    func unreadRecordHoldsTheToken() {
        let settled = PullAcknowledgement.settle(
            [
                Self.page(from: "t0", changed: ["a"]),
                Self.page(from: "t1", changed: ["c"], unread: ["b"]),
                Self.page(from: "t2", changed: ["d"])
            ],
            finalToken: "t3"
        )

        #expect(settled.token == "t1")
        #expect(settled.unread == [Self.id("b")])
    }

    @Test("A full fetch whose first page could not read a record acknowledges no token")
    func fullFetchKeepsNoToken() {
        let settled = PullAcknowledgement.settle([Self.page(from: nil, unread: ["b"])], finalToken: "t1")

        #expect(settled.token == nil)
        #expect(settled.unread == [Self.id("b")])
    }

    @Test("A record a later page changed or deleted no longer holds the token")
    func laterPageReleasesTheRecord() {
        let changedLater = PullAcknowledgement.settle(
            [Self.page(from: "t0", unread: ["b"]), Self.page(from: "t1", changed: ["b"])],
            finalToken: "t2"
        )
        let deletedLater = PullAcknowledgement.settle(
            [Self.page(from: "t0", unread: ["b"]), Self.page(from: "t1", deleted: ["b"])],
            finalToken: "t2"
        )

        #expect(changedLater.token == "t2")
        #expect(changedLater.unread.isEmpty)
        #expect(deletedLater.token == "t2")
        #expect(deletedLater.unread.isEmpty)
    }

    @Test("A record read before a later page failed on it still holds the token")
    func earlierReadDoesNotRelease() {
        let settled = PullAcknowledgement.settle(
            [Self.page(from: "t0", changed: ["b"]), Self.page(from: "t1", unread: ["b"])],
            finalToken: "t2"
        )

        #expect(settled.token == "t1")
        #expect(settled.unread == [Self.id("b")])
    }

    @Test("A record fetched again by ID no longer holds the token")
    func refetchedRecordReleasesTheToken() {
        let pages = [Self.page(from: "t0", unread: ["b"]), Self.page(from: "t1", unread: ["c"])]

        let partly = PullAcknowledgement.settle(pages, finalToken: "t2", resolved: [Self.id("b")])
        let fully = PullAcknowledgement.settle(pages, finalToken: "t2", resolved: [Self.id("b"), Self.id("c")])

        #expect(partly.token == "t1")
        #expect(partly.unread == [Self.id("c")])
        #expect(fully.token == "t2")
        #expect(fully.unread.isEmpty)
    }

    @Test("A record two pages failed on is listed once, and the earlier page holds the token")
    func repeatedFailureIsListedOnce() {
        let settled = PullAcknowledgement.settle(
            [Self.page(from: "t0", unread: ["b"]), Self.page(from: "t1", changed: ["a"]), Self.page(from: "t2", unread: ["b"])],
            finalToken: "t3"
        )

        #expect(settled.token == "t0")
        #expect(settled.unread == [Self.id("b")])
    }

    @Test("A record unread for the held number of pulls in a row is released, and the token moves past it")
    func recordIsReleasedAfterTheHeldPulls() {
        var ledger = UnreadRecordLedger()
        let pages = [Self.page(from: "t0", changed: ["a"]), Self.page(from: "t1", unread: ["b"])]

        for _ in 1 ..< UnreadRecordLedger.heldPulls {
            let held = PullAcknowledgement.settle(pages, finalToken: "t2", resolved: ledger.released)
            #expect(held.token == "t1")
            let releasing = ledger.countPull(holding: held.unread)
            #expect(releasing.isEmpty)
        }
        let last = PullAcknowledgement.settle(pages, finalToken: "t2", resolved: ledger.released)
        let releasing = ledger.countPull(holding: last.unread)
        #expect(releasing == [Self.id("b")])

        let released = PullAcknowledgement.settle(pages, finalToken: "t2", resolved: ledger.released)
        #expect(released.token == "t2")
        #expect(released.unread.isEmpty)
        #expect(ledger.released == [Self.id("b")])
    }

    @Test("A pull that reads the record starts its count over")
    func readingStartsTheCountOver() {
        var ledger = UnreadRecordLedger()

        var released: Set<CKRecord.ID> = []
        for _ in 1 ..< UnreadRecordLedger.heldPulls {
            released.formUnion(ledger.countPull(holding: [Self.id("b")]))
        }
        released.formUnion(ledger.countPull(holding: []))
        for _ in 1 ..< UnreadRecordLedger.heldPulls {
            released.formUnion(ledger.countPull(holding: [Self.id("b")]))
        }

        #expect(released.isEmpty)
        #expect(ledger.released.isEmpty)
    }

    @Test("A released record that reads by ID, or is gone, is forgotten")
    func releasedRecordIsForgottenOnceResolved() {
        var ledger = UnreadRecordLedger()
        for _ in 0 ..< UnreadRecordLedger.heldPulls {
            _ = ledger.countPull(holding: [Self.id("b"), Self.id("c")])
        }
        #expect(ledger.released == [Self.id("b"), Self.id("c")])

        ledger.forget([Self.id("b")])

        #expect(ledger.released == [Self.id("c")])
    }
}
