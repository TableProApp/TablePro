//
//  MongoWriteLedgerTests.swift
//  TableProTests
//

import Foundation
import Testing

/// The replies below are the canonical Extended JSON libmongoc 1.28.1 handed back from MongoDB
/// 7.0.43, so the ledger is tested against shapes the host actually sees.
struct MongoWriteLedgerTests {
    private static let validatorRejection = """
        { "n" : { "$numberInt" : "0" }, "writeErrors" : [ { "index" : { "$numberInt" : "0" }, \
        "code" : { "$numberInt" : "121" }, "errmsg" : "Document failed validation" } ], \
        "nModified" : { "$numberInt" : "0" }, "ok" : { "$numberDouble" : "1.0" } }
        """

    private static let rawInsertDuplicateAtTwo = """
        { "n" : { "$numberInt" : "2" }, "writeErrors" : [ { "index" : { "$numberInt" : "2" }, \
        "code" : { "$numberInt" : "11000" }, "errmsg" : "E11000 duplicate key error" } ], \
        "ok" : { "$numberDouble" : "1.0" } }
        """

    private static let crudInsertDuplicateAtTwo = """
        { "insertedCount" : { "$numberInt" : "2" }, "writeErrors" : [ { "index" : { "$numberInt" : "2" }, \
        "code" : { "$numberInt" : "11000" }, "errmsg" : "E11000 duplicate key error" } ] }
        """

    private static let maxTimeExpired = """
        { "ok" : { "$numberDouble" : "0.0" }, "errmsg" : "operation exceeded time limit", \
        "code" : { "$numberInt" : "50" }, "codeName" : "MaxTimeMSExpired" }
        """

    private static let interrupted = """
        { "ok" : { "$numberDouble" : "0.0" }, "errmsg" : "operation was interrupted", \
        "code" : { "$numberInt" : "11601" }, "codeName" : "Interrupted" }
        """

    private static let replicationRefused = """
        { "ok" : { "$numberDouble" : "0.0" }, "errmsg" : "cannot use 'w' > 1 when a host is not replicated", \
        "code" : { "$numberInt" : "2" }, "codeName" : "BadValue" }
        """

    private static func outcome(_ reply: String) -> MongoWriteOutcome {
        MongoWriteOutcome(replyJson: reply, failure: MongoWriteFailure.read(fromReply: reply))
    }

    private static func ledger(_ operation: MongoWriteOperation, touchesMany: Bool, reply: String) -> MongoWriteLedger {
        var ledger = MongoWriteLedger()
        ledger.record(operation, touchesMany: touchesMany, acknowledged: true, outcome: outcome(reply))
        return ledger
    }

    @Test("An updateMany that fails part-way may have changed documents its reply does not count")
    func updateManyDocumentErrorMayHaveChanged() {
        let ledger = Self.ledger(.update, touchesMany: true, reply: Self.validatorRejection)
        #expect(ledger.changed == 0)
        #expect(ledger.mayHaveChangedMore)
        #expect(ledger.note == MongoScriptText.writesMayHaveChanged)
    }

    @Test("An updateOne that fails changed nothing, so there is no note")
    func updateOneDocumentErrorChangedNothing() {
        let ledger = Self.ledger(.update, touchesMany: false, reply: Self.validatorRejection)
        #expect(ledger.changed == 0)
        #expect(!ledger.mayHaveChangedMore)
        #expect(ledger.note == nil)
    }

    @Test("An ordered insert counts the documents before the duplicate, from either reply shape")
    func insertCountsWhatLanded() {
        for reply in [Self.rawInsertDuplicateAtTwo, Self.crudInsertDuplicateAtTwo] {
            let ledger = Self.ledger(.insert, touchesMany: true, reply: reply)
            #expect(ledger.changed == 2)
            #expect(!ledger.mayHaveChangedMore)
            #expect(ledger.note == MongoScriptText.writesChanged(2))
        }
    }

    @Test("A multi-document write stopped by a timeout or a kill may have changed documents")
    func interruptedMultiWriteMayHaveChanged() {
        for operation in [MongoWriteOperation.update, .delete] {
            for reply in [Self.maxTimeExpired, Self.interrupted] {
                let ledger = Self.ledger(operation, touchesMany: true, reply: reply)
                #expect(ledger.mayHaveChangedMore)
                #expect(MongoWriteFailure.read(fromReply: reply)?.stoppedWhileRunning == true)
                #expect(ledger.note == MongoScriptText.writesMayHaveChanged)
            }
        }
    }

    @Test("A single-document write stopped by a timeout changed nothing and leaves nothing to report")
    func interruptedSingleWriteChangedNothing() {
        let ledger = Self.ledger(.update, touchesMany: false, reply: Self.maxTimeExpired)
        #expect(!ledger.mayHaveChangedMore)
        #expect(ledger.note == nil)
        #expect(ledger.isEmpty)
    }

    @Test("A command the server refused outright changed nothing")
    func refusedCommandChangedNothing() {
        let ledger = Self.ledger(.update, touchesMany: true, reply: Self.replicationRefused)
        #expect(ledger.changed == 0)
        #expect(!ledger.mayHaveChangedMore)
        #expect(ledger.note == nil)
    }

    @Test("A bulkWrite counts every operation that finished before the one that failed")
    func bulkSequenceMatchesMongosh() {
        var ledger = MongoWriteLedger()
        ledger.record(.insert, touchesMany: false, acknowledged: true, outcome: Self.outcome("""
            { "n" : { "$numberInt" : "1" }, "ok" : { "$numberDouble" : "1.0" } }
            """))
        ledger.record(.update, touchesMany: true, acknowledged: true, outcome: Self.outcome("""
            { "n" : { "$numberInt" : "4" }, "nModified" : { "$numberInt" : "4" }, "ok" : { "$numberDouble" : "1.0" } }
            """))
        ledger.record(.insert, touchesMany: false, acknowledged: true, outcome: Self.outcome("""
            { "n" : { "$numberInt" : "0" }, "writeErrors" : [ { "index" : { "$numberInt" : "0" }, \
            "code" : { "$numberInt" : "11000" }, "errmsg" : "E11000 duplicate key error" } ], \
            "ok" : { "$numberDouble" : "1.0" } }
            """))
        #expect(ledger.changed == 5)
        #expect(ledger.note == MongoScriptText.writesChanged(5))
    }

    @Test("A known count followed by an updateMany that failed part-way says both")
    func knownCountAndPossiblyMore() {
        var ledger = MongoWriteLedger()
        ledger.record(.delete, touchesMany: true, acknowledged: true, outcome: Self.outcome("""
            { "n" : { "$numberInt" : "3" }, "ok" : { "$numberDouble" : "1.0" } }
            """))
        ledger.record(.update, touchesMany: true, acknowledged: true, outcome: Self.outcome(Self.validatorRejection))
        #expect(ledger.note == MongoScriptText.writesChangedAndMaybeMore(3))
    }

    @Test("A write the servers did not confirm was still applied and counts")
    func unconfirmedWriteCounts() {
        let ledger = Self.ledger(.update, touchesMany: false, reply: """
            {"n":{"$numberInt":"1"},"nModified":{"$numberInt":"1"},"writeConcernError":{"code":{"$numberInt":"64"},\
            "errmsg":"waiting for replication timed out"},"ok":{"$numberDouble":"1.0"}}
            """)
        #expect(ledger.changed == 1)
        #expect(ledger.note == MongoScriptText.writesChanged(1))
    }

    @Test("Upserts count as changes and a findAndModify counts the document it reached")
    func upsertAndFindAndModifyCounts() {
        var ledger = MongoWriteLedger()
        ledger.record(.update, touchesMany: false, acknowledged: true, outcome: Self.outcome("""
            { "n" : { "$numberInt" : "1" }, "upserted" : [ { "index" : { "$numberInt" : "0" }, \
            "_id" : { "$numberInt" : "100" } } ], "nModified" : { "$numberInt" : "0" }, "ok" : { "$numberDouble" : "1.0" } }
            """))
        ledger.record(.findAndModify, touchesMany: false, acknowledged: true, outcome: Self.outcome("""
            { "lastErrorObject" : { "n" : { "$numberInt" : "1" }, "updatedExisting" : true }, \
            "value" : { "_id" : { "$numberInt" : "1" } }, "ok" : { "$numberDouble" : "1.0" } }
            """))
        #expect(ledger.changed == 2)
    }

    @Test("A write whose connection broke may have been applied, and one never sent was not")
    func unansweredAndNotSent() {
        var unanswered = MongoWriteLedger()
        unanswered.record(.update, touchesMany: false, acknowledged: true, outcome: MongoWriteOutcome(
            replyJson: "{}", failure: MongoWriteFailure(code: 6, message: "socket error", stage: .unanswered)
        ))
        #expect(unanswered.note == MongoScriptText.writesMayHaveChanged)

        var notSent = MongoWriteLedger()
        notSent.record(.update, touchesMany: true, acknowledged: true, outcome: MongoWriteOutcome(
            replyJson: "{}", failure: MongoWriteFailure(code: 13_053, message: "No suitable servers", stage: .notSent)
        ))
        #expect(notSent.changed == 0)
        #expect(notSent.note == nil)
    }

    @Test("An insert that stopped before sending every document still counts the batches that went")
    func notSentKeepsEarlierBatches() {
        var ledger = MongoWriteLedger()
        ledger.record(.insert, touchesMany: true, acknowledged: true, outcome: MongoWriteOutcome(
            replyJson: "{ \"insertedCount\" : { \"$numberInt\" : \"3\" } }",
            failure: MongoWriteFailure(
                code: 0, message: MongoScriptText.insertStoppedAtOversizedDocument, stage: .stoppedBetweenBatches
            )
        ))
        #expect(ledger.changed == 3)
        #expect(!ledger.mayHaveChangedMore)
        #expect(ledger.note == MongoScriptText.writesChanged(3))
    }

    @Test("An unacknowledged insert that stopped between batches may have written the batches that went")
    func unacknowledgedStopBetweenBatchesMayHaveChanged() {
        var ledger = MongoWriteLedger()
        ledger.record(.insert, touchesMany: true, acknowledged: false, outcome: MongoWriteOutcome(
            replyJson: "{ }",
            failure: MongoWriteFailure(
                code: 0, message: MongoScriptText.insertStoppedAtOversizedDocument, stage: .stoppedBetweenBatches
            )
        ))
        #expect(ledger.changed == 0)
        #expect(ledger.mayHaveChangedMore)
        #expect(ledger.note == MongoScriptText.writesMayHaveChanged)
    }

    @Test("A multi-document write stopped by an interruption code from MongoDB 8.0 on may have changed documents")
    func newerInterruptionsMayHaveChanged() {
        let codes: [UInt32] = [91_331, 10_045_600, 453, 471, 473, 485, 509]
        for code in codes {
            var ledger = MongoWriteLedger()
            ledger.record(.update, touchesMany: true, acknowledged: true, outcome: Self.outcome("""
                { "ok" : { "$numberDouble" : "0.0" }, "errmsg" : "interrupted", "code" : { "$numberInt" : "\(code)" } }
                """))
            #expect(ledger.mayHaveChangedMore, "\(code)")
            #expect(ledger.note == MongoScriptText.writesMayHaveChanged, "\(code)")
        }
    }

    @Test("A write sent with w: 0 may have changed documents whatever its reply counts")
    func unacknowledgedWriteMayHaveChanged() {
        let commandReply = """
            { "n" : { "$numberInt" : "0" }, "nModified" : { "$numberInt" : "0" }, "ok" : { "$numberDouble" : "1.0" } }
            """
        for (operation, reply) in [(MongoWriteOperation.update, commandReply), (.delete, commandReply), (.insert, "{ }")] {
            var ledger = MongoWriteLedger()
            ledger.record(operation, touchesMany: false, acknowledged: false, outcome: Self.outcome(reply))
            #expect(ledger.changed == 0)
            #expect(ledger.mayHaveChangedMore)
            #expect(ledger.note == MongoScriptText.writesMayHaveChanged)
        }
    }

    @Test("An unacknowledged write refused on this side changed nothing")
    func unacknowledgedWriteNotSent() {
        var ledger = MongoWriteLedger()
        ledger.record(.insert, touchesMany: true, acknowledged: false, outcome: MongoWriteOutcome(
            replyJson: "{ }", failure: MongoWriteFailure(code: 22, message: "Invalid writeConcern", stage: .notSent)
        ))
        #expect(ledger.note == nil)
        #expect(ledger.isEmpty)
    }

    @Test("A write still waiting on the server when the statement is abandoned may have been applied")
    func writeInFlight() {
        var ledger = MongoWriteLedger()
        ledger.beginWrite()
        #expect(ledger.note == MongoScriptText.writesMayHaveChanged)
        ledger.abandonWrite()
        #expect(ledger.note == nil)
        #expect(ledger.isEmpty)
    }
}

struct MongoWriteLedgerMessageTests {
    private static let timeoutText = "operation exceeded time limit"

    private static func ledger(recording failure: MongoWriteFailure, touchesMany: Bool) -> MongoWriteLedger {
        var ledger = MongoWriteLedger()
        ledger.record(
            .update, touchesMany: touchesMany, acknowledged: true,
            outcome: MongoWriteOutcome(replyJson: "{}", failure: failure)
        )
        return ledger
    }

    @Test("A write stopped by the timeout reads as a write, with the note after the timeout text")
    func writeTimeoutKeepsNote() {
        let ledger = Self.ledger(
            recording: MongoWriteFailure(code: 50, message: Self.timeoutText, stage: .command), touchesMany: true
        )
        #expect(ledger.reportedMessage(
            code: 50, message: Self.timeoutText, failedWrite: .command, maxTimeMS: 30_000
        ) == """
            \(MongoDBTimeoutPolicy.writeTimeoutMessage(maxTimeMS: 30_000))

            \(MongoScriptText.writesMayHaveChanged)
            """)
    }

    @Test("A read that times out after the script caught a write's timeout reads as a query, not a write")
    func readTimeoutAfterCaughtWriteTimeout() {
        let ledger = Self.ledger(
            recording: MongoWriteFailure(code: 50, message: Self.timeoutText, stage: .command), touchesMany: true
        )
        #expect(ledger.reportedMessage(
            code: 50, message: Self.timeoutText, failedWrite: nil, maxTimeMS: 1_000
        ) == """
            \(MongoDBTimeoutPolicy.timeoutMessage(maxTimeMS: 1_000))

            \(MongoScriptText.writesMayHaveChanged)
            """)
    }

    @Test("A single write stopped by the timeout reads as a write with nothing recorded before it")
    func singleWriteTimeout() {
        #expect(MongoWriteLedger().reportedMessage(
            code: 50, message: Self.timeoutText, failedWrite: .command, maxTimeMS: 1_000
        ) == MongoDBTimeoutPolicy.writeTimeoutMessage(maxTimeMS: 1_000))
    }

    @Test("A read timeout with nothing written keeps the read wording and no note")
    func readTimeout() {
        #expect(MongoWriteLedger().reportedMessage(
            code: 50, message: Self.timeoutText, failedWrite: nil, maxTimeMS: 30_000
        ) == MongoDBTimeoutPolicy.timeoutMessage(maxTimeMS: 30_000))
    }

    @Test("A read that times out after an earlier write keeps the read wording and adds the note")
    func readTimeoutAfterWrite() {
        var ledger = MongoWriteLedger()
        ledger.record(.delete, touchesMany: true, acknowledged: true, outcome: MongoWriteOutcome(replyJson: "{\"n\": 2}", failure: nil))
        #expect(ledger.reportedMessage(code: 50, message: Self.timeoutText, failedWrite: nil, maxTimeMS: 1_000) == """
            \(MongoDBTimeoutPolicy.timeoutMessage(maxTimeMS: 1_000))

            \(MongoScriptText.writesChanged(2))
            """)
    }

    @Test("A write-concern error with the timeout's code keeps the text that says the write was applied")
    func unconfirmedTimeoutKeepsItsText() {
        let applied = MongoScriptText.writeNotAcknowledged(reason: "waiting for replication timed out")
        var ledger = MongoWriteLedger()
        ledger.record(.update, touchesMany: false, acknowledged: true, outcome: MongoWriteOutcome(
            replyJson: "{\"n\": 1, \"nModified\": 1}",
            failure: MongoWriteFailure(code: 50, message: applied, stage: .unconfirmed)
        ))
        #expect(ledger.reportedMessage(code: 50, message: applied, failedWrite: .unconfirmed, maxTimeMS: 30_000) == """
            \(applied)

            \(MongoScriptText.writesChanged(1))
            """)
    }

    @Test("A server refusal keeps its message and gets the count of what was already written")
    func documentErrorWithCount() {
        var ledger = MongoWriteLedger()
        ledger.record(.insert, touchesMany: true, acknowledged: true, outcome: MongoWriteOutcome(
            replyJson: "{\"n\": 2}",
            failure: MongoWriteFailure(code: 121, message: "Document failed validation", stage: .document)
        ))
        #expect(ledger.reportedMessage(
            code: 121, message: "Document failed validation", failedWrite: .document, maxTimeMS: 30_000
        ) == """
            Document failed validation

            \(MongoScriptText.writesChanged(2))
            """)
    }

    @Test("With no query timeout set, a timeout code is left as the server wrote it")
    func noTimeoutConfigured() {
        #expect(MongoWriteLedger().reportedMessage(
            code: 50, message: Self.timeoutText, failedWrite: .command, maxTimeMS: nil
        ) == Self.timeoutText)
    }
}
