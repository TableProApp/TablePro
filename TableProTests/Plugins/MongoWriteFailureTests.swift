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
        #expect(MongoWriteFailure.read(fromReply: reply) == MongoWriteFailure(code: 121, message: "Document failed validation"))
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
            message: MongoScriptText.writeNotAcknowledged(reason: "waiting for replication timed out")
        ))
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

    @Test("A write concern error in a CRUD reply's array says the write was applied")
    func crudWriteConcernErrors() {
        let reply = """
            {"insertedCount":{"$numberInt":"0"},"matchedCount":{"$numberInt":"1"},"modifiedCount":{"$numberInt":"1"},\
            "upsertedCount":{"$numberInt":"0"},"writeConcernErrors":[{"code":{"$numberInt":"64"},\
            "errmsg":"waiting for replication timed out"}]}
            """
        #expect(MongoWriteFailure.read(fromReply: reply) == MongoWriteFailure(
            code: 64,
            message: MongoScriptText.writeNotAcknowledged(reason: "waiting for replication timed out")
        ))
    }

    @Test("A CRUD reply's writeErrors array gives the server's own message")
    func crudWriteErrors() {
        let reply = """
            {"insertedCount":{"$numberInt":"0"},"matchedCount":{"$numberInt":"0"},"modifiedCount":{"$numberInt":"0"},\
            "upsertedCount":{"$numberInt":"0"},"writeErrors":[{"index":{"$numberInt":"0"},"code":{"$numberInt":"121"},\
            "errmsg":"Document failed validation"}]}
            """
        #expect(MongoWriteFailure.read(fromReply: reply) == MongoWriteFailure(code: 121, message: "Document failed validation"))
    }
}

struct MongoScriptStatementFailureTests {
    @Test("A failure with no database switch is passed on unchanged")
    func noSwitch() {
        let error = MongoScriptError("boom")
        #expect(MongoScriptStatementFailure.carrying(error, databaseSwitch: nil) as? MongoScriptError == error)
    }

    @Test("A failure after a database switch carries the switch and keeps its message")
    func carriesSwitch() throws {
        let carried = MongoScriptStatementFailure.carrying(MongoScriptError("boom"), databaseSwitch: "reports")
        let failure = try #require(carried as? MongoScriptStatementFailure)
        #expect(failure.databaseSwitch == "reports")
        #expect(failure.localizedDescription == "boom")
    }
}
