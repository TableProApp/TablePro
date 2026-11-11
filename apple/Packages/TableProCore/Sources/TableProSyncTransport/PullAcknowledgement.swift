import CloudKit
import Foundation

// CloudKit ends each page of a zone fetch with a token past every change the page listed, read or not, so a delta
// never lists an unread record again. A pull acknowledges only up to the start of the first page holding a record
// that nothing after it read.
enum PullAcknowledgement {
    struct Page<Token> {
        let startToken: Token?
        let changed: Set<CKRecord.ID>
        let deleted: Set<CKRecord.ID>
        let unread: [CKRecord.ID]
    }

    struct Settled<Token> {
        let token: Token?
        let unread: [CKRecord.ID]
    }

    // A record a later page changed or deleted was read at a state no older than its failure. One in `resolved`
    // holds nothing either: it was read by ID, is gone, or was released by `UnreadRecordLedger`.
    static func settle<Token>(
        _ pages: [Page<Token>],
        finalToken: Token?,
        resolved: Set<CKRecord.ID> = []
    ) -> Settled<Token> {
        var token = finalToken
        var unread: [CKRecord.ID] = []
        var readLater = resolved
        for page in pages.reversed() {
            let stillUnread = page.unread.filter { !readLater.contains($0) }
            if !stillUnread.isEmpty {
                token = page.startToken
                unread.insert(contentsOf: stillUnread, at: 0)
            }
            readLater.formUnion(page.changed)
            readLater.formUnion(page.deleted)
        }
        var listed: Set<CKRecord.ID> = []
        return Settled(token: token, unread: unread.filter { listed.insert($0).inserted })
    }
}

// A record CloudKit keeps failing to deliver holds the token for `heldPulls` pulls in a row. Then it is released: the
// token moves past it, so sync and the full-fetch deletion check go on, and each later pull fetches it by ID until it
// reads or is gone. Kept for the life of the engine.
struct UnreadRecordLedger {
    static let heldPulls = 3

    private var pullsHeld: [CKRecord.ID: Int] = [:]
    private(set) var released: Set<CKRecord.ID> = []

    mutating func forget(_ recordIDs: Set<CKRecord.ID>) {
        released.subtract(recordIDs)
    }

    // Counts one more pull for each record that still holds the token; a record that stopped holding starts over.
    // Returns the records this pull releases.
    mutating func countPull(holding recordIDs: [CKRecord.ID]) -> Set<CKRecord.ID> {
        let holding = Set(recordIDs)
        pullsHeld = pullsHeld.filter { holding.contains($0.key) }
        var releasing: Set<CKRecord.ID> = []
        for recordID in holding {
            let pulls = (pullsHeld[recordID] ?? 0) + 1
            if pulls >= Self.heldPulls {
                releasing.insert(recordID)
                pullsHeld[recordID] = nil
            } else {
                pullsHeld[recordID] = pulls
            }
        }
        released.formUnion(releasing)
        return releasing
    }
}
