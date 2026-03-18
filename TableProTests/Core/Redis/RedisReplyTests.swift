//
//  RedisReplyTests.swift
//  TableProTests
//
//  Tests for RedisReply, the structured representation of Redis server responses.
//
//  The type lives inside RedisDriverPlugin (a bundle target), so we copy
//  the pure-value enum here as a private local helper instead of using @testable import.
//

import Foundation
import Testing

// MARK: - stringValue

@Suite("RedisReply - stringValue")
struct RedisReplyStringValueTests {
    @Test("string case returns the string")
    func stringCase() {
        let reply = TestRedisReply.string("hello")
        #expect(reply.stringValue == "hello")
    }

    @Test("status case returns the status string")
    func statusCase() {
        let reply = TestRedisReply.status("OK")
        #expect(reply.stringValue == "OK")
    }

    @Test("data case returns UTF-8 decoded string")
    func dataCase() {
        let data = "binary content".data(using: .utf8)!
        let reply = TestRedisReply.data(data)
        #expect(reply.stringValue == "binary content")
    }

    @Test("integer case returns nil")
    func integerCase() {
        let reply = TestRedisReply.integer(42)
        #expect(reply.stringValue == nil)
    }

    @Test("null case returns nil")
    func nullCase() {
        let reply = TestRedisReply.null
        #expect(reply.stringValue == nil)
    }

    @Test("error case returns nil")
    func errorCase() {
        let reply = TestRedisReply.error("ERR unknown command")
        #expect(reply.stringValue == nil)
    }

    @Test("array case returns nil")
    func arrayCase() {
        let reply = TestRedisReply.array([.string("a")])
        #expect(reply.stringValue == nil)
    }
}

// MARK: - intValue

@Suite("RedisReply - intValue")
struct RedisReplyIntValueTests {
    @Test("integer case returns the integer")
    func integerCase() {
        let reply = TestRedisReply.integer(99)
        #expect(reply.intValue == 99)
    }

    @Test("string case with parseable integer returns the integer")
    func stringParseableCase() {
        let reply = TestRedisReply.string("123")
        #expect(reply.intValue == 123)
    }

    @Test("string case with non-parseable value returns nil")
    func stringNonParseableCase() {
        let reply = TestRedisReply.string("not a number")
        #expect(reply.intValue == nil)
    }

    @Test("null case returns nil")
    func nullCase() {
        let reply = TestRedisReply.null
        #expect(reply.intValue == nil)
    }

    @Test("data case returns nil")
    func dataCase() {
        let reply = TestRedisReply.data(Data([0x01, 0x02]))
        #expect(reply.intValue == nil)
    }

    @Test("status case returns nil")
    func statusCase() {
        let reply = TestRedisReply.status("OK")
        #expect(reply.intValue == nil)
    }

    @Test("large Int64 value converts correctly")
    func largeInt64() {
        let reply = TestRedisReply.integer(Int64.max)
        #expect(reply.intValue == Int(Int64.max))
    }
}

// MARK: - stringArrayValue

@Suite("RedisReply - stringArrayValue")
struct RedisReplyStringArrayValueTests {
    @Test("array of strings returns string array")
    func arrayOfStrings() {
        let reply = TestRedisReply.array([.string("a"), .string("b"), .string("c")])
        #expect(reply.stringArrayValue == ["a", "b", "c"])
    }

    @Test("array with nulls compacts them out")
    func arrayWithNulls() {
        let reply = TestRedisReply.array([.string("a"), .null, .string("c")])
        #expect(reply.stringArrayValue == ["a", "c"])
    }

    @Test("array with status values includes them")
    func arrayWithStatus() {
        let reply = TestRedisReply.array([.status("OK"), .string("val")])
        #expect(reply.stringArrayValue == ["OK", "val"])
    }

    @Test("array with integers excludes them (no stringValue)")
    func arrayWithIntegers() {
        let reply = TestRedisReply.array([.string("a"), .integer(42)])
        #expect(reply.stringArrayValue == ["a"])
    }

    @Test("non-array returns nil")
    func nonArray() {
        let reply = TestRedisReply.string("not an array")
        #expect(reply.stringArrayValue == nil)
    }

    @Test("null returns nil")
    func nullCase() {
        let reply = TestRedisReply.null
        #expect(reply.stringArrayValue == nil)
    }

    @Test("empty array returns empty array")
    func emptyArray() {
        let reply = TestRedisReply.array([])
        #expect(reply.stringArrayValue == [])
    }
}

// MARK: - arrayValue

@Suite("RedisReply - arrayValue")
struct RedisReplyArrayValueTests {
    @Test("array returns the inner array")
    func arrayCase() {
        let inner: [TestRedisReply] = [.string("a"), .integer(1), .null]
        let reply = TestRedisReply.array(inner)
        let result = reply.arrayValue
        #expect(result?.count == 3)
    }

    @Test("null returns nil")
    func nullCase() {
        let reply = TestRedisReply.null
        #expect(reply.arrayValue == nil)
    }

    @Test("string returns nil")
    func stringCase() {
        let reply = TestRedisReply.string("hello")
        #expect(reply.arrayValue == nil)
    }

    @Test("integer returns nil")
    func integerCase() {
        let reply = TestRedisReply.integer(42)
        #expect(reply.arrayValue == nil)
    }

    @Test("nested array is accessible")
    func nestedArray() {
        let inner = TestRedisReply.array([.string("nested")])
        let reply = TestRedisReply.array([inner, .string("top")])
        let result = reply.arrayValue
        #expect(result?.count == 2)
        if let first = result?.first, case .array(let nested) = first {
            #expect(nested.count == 1)
        } else {
            Issue.record("Expected nested array")
        }
    }
}

// MARK: - Private Local Helper (copied from RedisDriverPlugin)

private enum TestRedisReply {
    case string(String)
    case integer(Int64)
    case array([TestRedisReply])
    case data(Data)
    case status(String)
    case error(String)
    case null

    var stringValue: String? {
        switch self {
        case .string(let s), .status(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let i): return Int(i)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var stringArrayValue: [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap(\.stringValue)
    }

    var arrayValue: [TestRedisReply]? {
        guard case .array(let items) = self else { return nil }
        return items
    }
}
