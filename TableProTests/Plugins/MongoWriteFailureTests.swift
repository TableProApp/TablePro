//
//  MongoWriteFailureTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MongoWriteFailureTests {
    @Test("A validator rejection under ok: 1 is a failure")
    func validatorRejection() {
        let reply = """
            {"n":{"$numberInt":"0"},"writeErrors":[{"index":{"$numberInt":"0"},"code":{"$numberInt":"121"},\
            "errmsg":"Document failed validation","errInfo":{"failingDocumentId":{"$oid":"6ab6cea9cc5310bead7fd537"},\
            "details":{"operatorName":"$jsonSchema"}}}],"nModified":{"$numberInt":"0"},"ok":{"$numberInt":"1"}}
            """
        #expect(MongoWriteFailure.read(fromReply: reply) == MongoWriteFailure(
            code: 121, message: "Document failed validation", stage: .document
        ))
    }

    @Test("An update that would change _id is a failure")
    func immutableId() {
        let reply = """
            {"n":{"$numberInt":"0"},"writeErrors":[{"index":{"$numberInt":"0"},"code":{"$numberInt":"66"},\
            "errmsg":"Performing an update on the path '_id' would modify the immutable field '_id'"}],\
            "nModified":{"$numberInt":"0"},"ok":{"$numberInt":"1"}}
            """
        let failure = MongoWriteFailure.read(fromReply: reply)
        #expect(failure?.code == 66)
        #expect(failure?.message == "Performing an update on the path '_id' would modify the immutable field '_id'")
    }

    @Test("A duplicate key is a failure")
    func duplicateKey() {
        let reply = """
            {"n":{"$numberInt":"0"},"writeErrors":[{"index":{"$numberInt":"0"},"code":{"$numberInt":"11000"},\
            "errmsg":"E11000 duplicate key error collection: v.u index: k_1 dup key: { k: 1 }",\
            "keyPattern":{"k":{"$numberInt":"1"}},"keyValue":{"k":{"$numberInt":"1"}}}],\
            "nModified":{"$numberInt":"0"},"ok":{"$numberInt":"1"}}
            """
        #expect(MongoWriteFailure.read(fromReply: reply)?.code == 11_000)
    }

    @Test("A write concern error is a failure that says the write was applied")
    func writeConcernError() {
        let reply = """
            {"n":{"$numberInt":"1"},"nModified":{"$numberInt":"1"},"writeConcernError":{"code":{"$numberInt":"64"},\
            "codeName":"WriteConcernFailed","errmsg":"waiting for replication timed out"},"ok":{"$numberInt":"1"}}
            """
        #expect(MongoWriteFailure.read(fromReply: reply) == MongoWriteFailure(
            code: 64,
            message: MongoScriptText.writeNotAcknowledged(reason: "waiting for replication timed out"),
            stage: .unconfirmed
        ))
    }

    @Test("The insert call's plural writeConcernErrors also says the write was applied")
    func pluralWriteConcernErrors() {
        let reply = """
            {"insertedCount":{"$numberInt":"1"},"writeConcernErrors":[{"code":{"$numberInt":"64"},\
            "errmsg":"waiting for replication timed out"}]}
            """
        #expect(MongoWriteFailure.read(fromReply: reply) == MongoWriteFailure(
            code: 64,
            message: MongoScriptText.writeNotAcknowledged(reason: "waiting for replication timed out"),
            stage: .unconfirmed
        ))
    }

    @Test("A command the server stopped carries the server's own code and message")
    func commandStoppedByTimeout() {
        let reply = """
            { "ok" : { "$numberDouble" : "0.0" }, "errmsg" : "operation exceeded time limit", \
            "code" : { "$numberInt" : "50" }, "codeName" : "MaxTimeMSExpired" }
            """
        let failure = MongoWriteFailure.read(fromReply: reply)
        #expect(failure == MongoWriteFailure(code: 50, message: "operation exceeded time limit", stage: .command))
        #expect(failure?.stoppedWhileRunning == true)
    }

    @Test("A command the server refused outright did not stop while running")
    func commandRefused() {
        let reply = """
            { "ok" : { "$numberDouble" : "0.0" }, "errmsg" : "cannot use 'w' > 1 when a host is not replicated", \
            "code" : { "$numberInt" : "2" }, "codeName" : "BadValue" }
            """
        let failure = MongoWriteFailure.read(fromReply: reply)
        #expect(failure?.stage == .command)
        #expect(failure?.code == 2)
        #expect(failure?.message == "cannot use 'w' > 1 when a host is not replicated")
        #expect(failure?.stoppedWhileRunning == false)
    }

    @Test("The insert call's errorReplies carry the server's refusal")
    func errorReplies() {
        let reply = """
            { "insertedCount" : { "$numberInt" : "0" }, "errorReplies" : [ { "ok" : { "$numberDouble" : "0.0" }, \
            "errmsg" : "cannot use 'w' > 1 when a host is not replicated", "code" : { "$numberInt" : "2" }, \
            "codeName" : "BadValue" } ] }
            """
        #expect(MongoWriteFailure.read(fromReply: reply) == MongoWriteFailure(
            code: 2, message: "cannot use 'w' > 1 when a host is not replicated", stage: .command
        ))
    }

    @Test("A reply with no server answer is left to the caller's error domain")
    func noServerAnswer() {
        #expect(MongoWriteFailure.read(fromReply: "{}") == nil)
        #expect(MongoWriteFailure.read(fromReply: "{\"errorLabels\":[\"RetryableWriteError\"]}") == nil)
    }

    @Test("The first write error wins over a write concern error")
    func writeErrorsBeforeConcern() {
        let reply = """
            {"writeErrors":[{"index":0,"code":121,"errmsg":"Document failed validation"}],\
            "writeConcernError":{"code":64,"errmsg":"waiting for replication timed out"},"ok":1}
            """
        #expect(MongoWriteFailure.read(fromReply: reply)?.code == 121)
    }

    @Test("A clean reply, including one that matched nothing, is not a failure")
    func cleanReplies() {
        #expect(MongoWriteFailure.read(fromReply: """
            {"n":{"$numberInt":"2"},"nModified":{"$numberInt":"2"},"ok":{"$numberInt":"1"}}
            """) == nil)
        #expect(MongoWriteFailure.read(fromReply: """
            {"n":{"$numberInt":"0"},"ok":{"$numberInt":"1"}}
            """) == nil)
        #expect(MongoWriteFailure.read(fromReply: "{\"writeErrors\":[],\"ok\":1}") == nil)
    }

    @Test("An entry without a message still names its code")
    func missingMessage() {
        let failure = MongoWriteFailure.read(fromReply: "{\"writeErrors\":[{\"index\":0,\"code\":2}],\"ok\":1}")
        #expect(failure?.code == 2)
        #expect(failure?.message == MongoScriptText.writeRefused(code: 2))
    }

    @Test("Text that is not a reply reads as no failure")
    func unreadableReply() {
        #expect(MongoWriteFailure.read(fromReply: "") == nil)
        #expect(MongoWriteFailure.read(fromReply: "[1, 2]") == nil)
    }
}

struct MongoScriptStatementFailureTests {
    @Test("A failure with no database switch and no writes is passed on unchanged")
    func noSwitch() {
        let error = MongoScriptError("boom")
        let carried = MongoScriptStatementFailure.carrying(error, databaseSwitch: nil, writes: MongoWriteLedger())
        #expect(carried as? MongoScriptError == error)
    }

    @Test("A failure after a database switch carries the switch and keeps its message")
    func carriesSwitch() throws {
        let carried = MongoScriptStatementFailure.carrying(
            MongoScriptError("boom"), databaseSwitch: "reports", writes: MongoWriteLedger()
        )
        let failure = try #require(carried as? MongoScriptStatementFailure)
        #expect(failure.databaseSwitch == "reports")
        #expect(failure.localizedDescription == "boom")
    }

    @Test("A failure after a write carries the ledger and names what was written")
    func carriesWrites() throws {
        var writes = MongoWriteLedger()
        writes.record(
            .insert, touchesMany: false, acknowledged: true,
            outcome: MongoWriteOutcome(replyJson: "{\"n\": 1}", failure: nil)
        )
        let carried = MongoScriptStatementFailure.carrying(MongoScriptError("boom"), databaseSwitch: nil, writes: writes)
        let failure = try #require(carried as? MongoScriptStatementFailure)
        #expect(failure.databaseSwitch == nil)
        #expect(failure.writes == writes)
        #expect(failure.localizedDescription == "boom\n\n\(MongoScriptText.writesChanged(1))")
    }

    @Test("A write that failed and changed nothing is passed on as itself, its stage with it")
    func failedWriteWithNoChangeKeepsItsStage() throws {
        var writes = MongoWriteLedger()
        let stopped = MongoWriteFailure(code: 50, message: "operation exceeded time limit", stage: .command)
        writes.record(
            .update, touchesMany: false, acknowledged: true,
            outcome: MongoWriteOutcome(replyJson: "{}", failure: stopped)
        )
        let carried = MongoScriptStatementFailure.carrying(stopped, databaseSwitch: nil, writes: writes)
        #expect(carried as? MongoWriteFailure == stopped)
        #expect(carried.localizedDescription == "operation exceeded time limit")
    }

    @Test("A failed write crosses the bridge with its stage")
    func bridgeCarriesStage() throws {
        let failure = MongoWriteFailure(code: 50, message: "operation \"exceeded\" time limit", stage: .unconfirmed)
        let data = try #require(MongoScriptJson.failure(failure).data(using: .utf8))
        let response = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try #require(response["e"] as? [String: Any])
        #expect(response["ok"] as? Bool == false)
        #expect(error["m"] as? String == failure.message)
        #expect(error["c"] as? Int == 50)
        #expect(error["s"] as? String == "unconfirmed")
    }
}
