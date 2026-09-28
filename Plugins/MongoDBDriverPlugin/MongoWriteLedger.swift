import Foundation

enum MongoWriteOperation: Equatable, Sendable {
    case insert
    case update
    case delete
    case findAndModify
}

/// What one statement has already written, so a failure can say so.
///
/// MongoDB undoes nothing outside a transaction. An `updateMany` that fails on its third document
/// keeps the first two, an ordered `insertMany` keeps every document before the duplicate, and a
/// multi-document write stopped by a timeout keeps whatever it reached. The error alone reads as
/// if nothing happened, and running the statement again applies the change twice.
///
/// The count comes from each reply, and where a reply cannot tell, the ledger says documents may
/// have changed rather than guessing a number: an `updateMany` that fails part-way replies
/// `nModified: 0` however many it changed first. A write sent with `w: 0` cannot tell either: the
/// server answers it with `n: 0` whatever it changed, and says nothing of a write it refused.
///
/// A failure that stopped a write before it was sent still counts what the reply says was written
/// first. libmongoc sends a large `insertMany` in batches, and one that stops at a document it
/// cannot send has already inserted the batches before it.
struct MongoWriteLedger: Equatable, Sendable {
    private(set) var changed = 0
    private(set) var mayHaveChangedMore = false
    private(set) var isWriting = false

    var isEmpty: Bool { self == MongoWriteLedger() }

    mutating func beginWrite() {
        isWriting = true
    }

    mutating func abandonWrite() {
        isWriting = false
    }

    mutating func record(
        _ operation: MongoWriteOperation,
        touchesMany: Bool,
        acknowledged: Bool,
        outcome: MongoWriteOutcome
    ) {
        isWriting = false
        let applied = Self.appliedCount(operation, reply: outcome.replyJson)
        guard let failure = outcome.failure else {
            guard acknowledged else {
                mayHaveChangedMore = true
                return
            }
            changed += applied
            return
        }
        changed += applied
        switch failure.stage {
        case .unconfirmed, .notSent:
            break
        case .stoppedBetweenBatches:
            if !acknowledged { mayHaveChangedMore = true }
        case .document:
            if operation != .insert, touchesMany { mayHaveChangedMore = true }
        case .command:
            if failure.stoppedWhileRunning, touchesMany { mayHaveChangedMore = true }
        case .unanswered:
            mayHaveChangedMore = true
        }
    }

    /// A write still waiting on the server when the statement was abandoned may have been applied.
    var note: String? {
        let unknown = mayHaveChangedMore || isWriting
        switch (changed, unknown) {
        case (0, false): return nil
        case (0, true): return MongoScriptText.writesMayHaveChanged
        case (let count, false): return MongoScriptText.writesChanged(count)
        case (let count, true): return MongoScriptText.writesChangedAndMaybeMore(count)
        }
    }

    /// The message a failed statement reports: the timeout wording first, the note after it.
    ///
    /// `failedWrite` is the stage of the write whose failure escaped the statement, and nil when
    /// what escaped was not a write's failure. Only a server timeout is reworded, as a write when a
    /// write's failure escaped and as a query otherwise. A write-concern error keeps its own text
    /// even when its code is the timeout's, because that text is the one that says the write was
    /// applied.
    func reportedMessage(
        code: UInt32,
        message: String,
        failedWrite: MongoWriteFailure.Stage?,
        maxTimeMS: Int32?
    ) -> String {
        let base = timeoutMessage(code: code, failedWrite: failedWrite, maxTimeMS: maxTimeMS) ?? message
        guard let note else { return base }
        return "\(base)\n\n\(note)"
    }

    private func timeoutMessage(code: UInt32, failedWrite: MongoWriteFailure.Stage?, maxTimeMS: Int32?) -> String? {
        guard MongoDBTimeoutPolicy.isTimeoutCode(code), let maxTimeMS else { return nil }
        switch failedWrite {
        case nil:
            return MongoDBTimeoutPolicy.timeoutMessage(maxTimeMS: maxTimeMS)
        case .unconfirmed:
            return nil
        case .document, .command, .unanswered, .notSent, .stoppedBetweenBatches:
            return MongoDBTimeoutPolicy.writeTimeoutMessage(maxTimeMS: maxTimeMS)
        }
    }

    private static func appliedCount(_ operation: MongoWriteOperation, reply: String) -> Int {
        switch operation {
        case .insert:
            return count(in: reply, key: "insertedCount") ?? count(in: reply, key: "n") ?? 0
        case .update:
            let upserted = MongoScriptJson.member(of: reply, key: "upserted")
                .map { MongoScriptJson.topLevelElements($0).count } ?? 0
            return (count(in: reply, key: "nModified") ?? 0) + upserted
        case .delete:
            return count(in: reply, key: "n") ?? 0
        case .findAndModify:
            return MongoScriptJson.member(of: reply, key: "lastErrorObject")
                .flatMap { count(in: $0, key: "n") } ?? 0
        }
    }

    private static func count(in json: String, key: String) -> Int? {
        MongoScriptJson.number(in: json, key: key).map { Int(clamping: max(0, $0)) }
    }
}
