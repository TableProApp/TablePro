//
//  RedisReplyTests.swift
//  TableProTests
//
//  Tests for RedisReply, the structured representation of Redis server responses.
//
//  These used to run against a copy of the enum kept in this file, so they proved nothing about
//  the type the driver actually uses. RedisReply now lives in its own file that the test target
//  compiles, so they run against the real one.
//

import Foundation
import TableProPluginKit
import Testing

// MARK: - stringValue

@Suite("RedisReply - stringValue")
struct RedisReplyStringValueTests {
    @Test("string case returns the string")
    func stringCase() {
        let reply = RedisReply.string("hello")
        #expect(reply.stringValue == "hello")
    }

    @Test("status case returns the status string")
    func statusCase() {
        let reply = RedisReply.status("OK")
        #expect(reply.stringValue == "OK")
    }

    @Test("data case returns UTF-8 decoded string")
    func dataCase() {
        let data = "binary content".data(using: .utf8)!
        let reply = RedisReply.data(data)
        #expect(reply.stringValue == "binary content")
    }

    @Test("integer case returns nil")
    func integerCase() {
        let reply = RedisReply.integer(42)
        #expect(reply.stringValue == nil)
    }

    @Test("null case returns nil")
    func nullCase() {
        let reply = RedisReply.null
        #expect(reply.stringValue == nil)
    }

    @Test("error case returns nil")
    func errorCase() {
        let reply = RedisReply.error("ERR unknown command")
        #expect(reply.stringValue == nil)
    }

    @Test("array case returns nil")
    func arrayCase() {
        let reply = RedisReply.array([.string("a")])
        #expect(reply.stringValue == nil)
    }
}

// MARK: - intValue

@Suite("RedisReply - intValue")
struct RedisReplyIntValueTests {
    @Test("integer case returns the integer")
    func integerCase() {
        let reply = RedisReply.integer(99)
        #expect(reply.intValue == 99)
    }

    @Test("string case with parseable integer returns the integer")
    func stringParseableCase() {
        let reply = RedisReply.string("123")
        #expect(reply.intValue == 123)
    }

    @Test("string case with non-parseable value returns nil")
    func stringNonParseableCase() {
        let reply = RedisReply.string("not a number")
        #expect(reply.intValue == nil)
    }

    @Test("null case returns nil")
    func nullCase() {
        let reply = RedisReply.null
        #expect(reply.intValue == nil)
    }

    @Test("data case returns nil")
    func dataCase() {
        let reply = RedisReply.data(Data([0x01, 0x02]))
        #expect(reply.intValue == nil)
    }

    @Test("status case returns nil")
    func statusCase() {
        let reply = RedisReply.status("OK")
        #expect(reply.intValue == nil)
    }

    @Test("large Int64 value converts correctly")
    func largeInt64() {
        let reply = RedisReply.integer(Int64.max)
        #expect(reply.intValue == Int(Int64.max))
    }
}

// MARK: - stringArrayValue

@Suite("RedisReply - stringArrayValue")
struct RedisReplyStringArrayValueTests {
    @Test("array of strings returns string array")
    func arrayOfStrings() {
        let reply = RedisReply.array([.string("a"), .string("b"), .string("c")])
        #expect(reply.stringArrayValue == ["a", "b", "c"])
    }

    @Test("array with nulls compacts them out")
    func arrayWithNulls() {
        let reply = RedisReply.array([.string("a"), .null, .string("c")])
        #expect(reply.stringArrayValue == ["a", "c"])
    }

    @Test("array with status values includes them")
    func arrayWithStatus() {
        let reply = RedisReply.array([.status("OK"), .string("val")])
        #expect(reply.stringArrayValue == ["OK", "val"])
    }

    @Test("array with integers excludes them (no stringValue)")
    func arrayWithIntegers() {
        let reply = RedisReply.array([.string("a"), .integer(42)])
        #expect(reply.stringArrayValue == ["a"])
    }

    @Test("non-array returns nil")
    func nonArray() {
        let reply = RedisReply.string("not an array")
        #expect(reply.stringArrayValue == nil)
    }

    @Test("null returns nil")
    func nullCase() {
        let reply = RedisReply.null
        #expect(reply.stringArrayValue == nil)
    }

    @Test("empty array returns empty array")
    func emptyArray() {
        let reply = RedisReply.array([])
        #expect(reply.stringArrayValue == [])
    }
}

// MARK: - arrayValue

@Suite("RedisReply - arrayValue")
struct RedisReplyArrayValueTests {
    @Test("array returns the inner array")
    func arrayCase() {
        let inner: [RedisReply] = [.string("a"), .integer(1), .null]
        let reply = RedisReply.array(inner)
        let result = reply.arrayValue
        #expect(result?.count == 3)
    }

    @Test("null returns nil")
    func nullCase() {
        let reply = RedisReply.null
        #expect(reply.arrayValue == nil)
    }

    @Test("string returns nil")
    func stringCase() {
        let reply = RedisReply.string("hello")
        #expect(reply.arrayValue == nil)
    }

    @Test("integer returns nil")
    func integerCase() {
        let reply = RedisReply.integer(42)
        #expect(reply.arrayValue == nil)
    }

    @Test("nested array is accessible")
    func nestedArray() {
        let inner = RedisReply.array([.string("nested")])
        let reply = RedisReply.array([inner, .string("top")])
        let result = reply.arrayValue
        #expect(result?.count == 2)
        if let first = result?.first, case .array(let nested) = first {
            #expect(nested.count == 1)
        } else {
            Issue.record("Expected nested array")
        }
    }
}
