//
//  RedisReplyErrorTests.swift
//  TableProTests
//
//  hiredis returns a server error as an ordinary reply with no error set on the context, so a
//  caller that does not look reports success for a command the server refused. A cell edit
//  against a read-only replica used to be lost exactly this way.
//

import Foundation
import Testing

@Suite("Redis reply - error detection")
struct RedisReplyErrorDetectionTests {
    @Test("An error reply is recognised")
    func recognisesError() {
        #expect(RedisReply.error("READONLY You can't write against a read only replica.").isError)
        #expect(RedisReply.error("x").errorMessage == "x")
    }

    static let successes: [RedisReply] = [
        .status("OK"),
        .string("value"),
        .integer(1),
        .array([]),
        .null,
        .data(Data([0x01])),
    ]

    @Test("Every other reply shape is not an error", arguments: successes)
    func otherShapesAreNotErrors(reply: RedisReply) {
        #expect(!reply.isError)
        #expect(reply.errorMessage == nil)
    }
}

@Suite("Redis reply - throwIfError")
struct RedisReplyThrowTests {
    @Test("A READONLY reply throws rather than passing for success")
    func throwsOnReadOnly() {
        #expect(throws: RedisPluginError.self) {
            try RedisReply.error("READONLY You can't write against a read only replica.").throwIfError()
        }
    }

    @Test("The command name is carried into the message")
    func includesContext() throws {
        do {
            try RedisReply.error("WRONGTYPE").throwIfError("SET")
            Issue.record("expected a throw")
        } catch let error as RedisPluginError {
            #expect(error.message.contains("SET"))
            #expect(error.message.contains("WRONGTYPE"))
        }
    }

    @Test("Without a command name the server's text stands alone")
    func withoutContext() throws {
        do {
            try RedisReply.error("NOPERM").throwIfError()
            Issue.record("expected a throw")
        } catch let error as RedisPluginError {
            #expect(error.message == "NOPERM")
        }
    }

    @Test("A successful reply passes straight through")
    func passesThroughSuccess() throws {
        let reply = try RedisReply.status("OK").throwIfError("SET")
        #expect(reply.stringValue == "OK")
    }

    @Test("A nil reply is a value, not a failure, because a missing key is not an error")
    func nilIsNotAnError() throws {
        _ = try RedisReply.null.throwIfError("GET")
    }
}

@Suite("Redis transport failure")
struct RedisTransportFailureTests {
    @Test("A failure records whether the command reached the server")
    func recordsDelivery() {
        let undelivered = RedisTransportFailure(code: 1, message: "write failed", wasDelivered: false)
        let delivered = RedisTransportFailure(code: 1, message: "read timed out", wasDelivered: true)
        #expect(!undelivered.wasDelivered)
        #expect(delivered.wasDelivered)
    }

    @Test("It presents its message to the app like any other driver error")
    func presentsMessage() {
        let failure = RedisTransportFailure(code: 1, message: "read timed out", wasDelivered: true)
        #expect(failure.pluginErrorMessage == "read timed out")
        #expect(failure.pluginErrorCode == 1)
    }
}
