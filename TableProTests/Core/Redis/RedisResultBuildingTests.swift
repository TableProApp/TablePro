//
//  RedisResultBuildingTests.swift
//  TableProTests
//
//  Regression tests for the Redis build*Result methods.
//
//  The original bug: build methods used `stringArrayValue` (compactMap(\.stringValue))
//  which silently dropped `.data`, `.null`, and `.integer` entries, corrupting
//  alternating field/value pairs in hashes and other paired structures.
//  The fix switched to `arrayValue` (raw [RedisReply]) + `redisReplyToString()`.
//
//  Because RedisPluginDriver lives in a plugin bundle and cannot be @testable
//  imported, we replicate the fixed logic here as private helpers.
//

import Foundation
import Testing

// MARK: - Private Local Helpers (copied from RedisDriverPlugin)

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

// MARK: - Fixed Logic Replicas

/// Matches the fixed `redisReplyToString` in RedisPluginDriver.
private func testRedisReplyToString(_ reply: TestRedisReply) -> String {
    switch reply {
    case .string(let s), .status(let s), .error(let s): return s
    case .integer(let i): return String(i)
    case .data(let d): return String(data: d, encoding: .utf8) ?? d.base64EncodedString()
    case .array(let items): return "[\(items.map { testRedisReplyToString($0) }.joined(separator: ", "))]"
    case .null: return "(nil)"
    }
}

/// Result type mirroring the relevant fields of PluginQueryResult.
private struct TestResult {
    let columns: [String]
    let rows: [[String?]]
}

private func buildTestHashResult(_ result: TestRedisReply) -> TestResult {
    guard let items = result.arrayValue, !items.isEmpty else {
        return TestResult(columns: ["Field", "Value"], rows: [])
    }

    var rows: [[String?]] = []
    var i = 0
    while i + 1 < items.count {
        rows.append([testRedisReplyToString(items[i]), testRedisReplyToString(items[i + 1])])
        i += 2
    }

    return TestResult(columns: ["Field", "Value"], rows: rows)
}

private func buildTestListResult(_ result: TestRedisReply, startOffset: Int = 0) -> TestResult {
    guard let items = result.arrayValue else {
        return TestResult(columns: ["Index", "Value"], rows: [])
    }

    let rows = items.enumerated().map { index, item -> [String?] in
        [String(startOffset + index), testRedisReplyToString(item)]
    }

    return TestResult(columns: ["Index", "Value"], rows: rows)
}

private func buildTestSetResult(_ result: TestRedisReply) -> TestResult {
    guard let items = result.arrayValue else {
        return TestResult(columns: ["Member"], rows: [])
    }

    let rows = items.map { [testRedisReplyToString($0)] as [String?] }
    return TestResult(columns: ["Member"], rows: rows)
}

private func buildTestSortedSetResult(_ result: TestRedisReply, withScores: Bool) -> TestResult {
    guard let items = result.arrayValue else {
        return TestResult(
            columns: withScores ? ["Member", "Score"] : ["Member"],
            rows: []
        )
    }

    if withScores {
        var rows: [[String?]] = []
        var i = 0
        while i + 1 < items.count {
            rows.append([testRedisReplyToString(items[i]), testRedisReplyToString(items[i + 1])])
            i += 2
        }
        return TestResult(columns: ["Member", "Score"], rows: rows)
    } else {
        let rows = items.map { [testRedisReplyToString($0)] as [String?] }
        return TestResult(columns: ["Member"], rows: rows)
    }
}

private func buildTestConfigResult(_ result: TestRedisReply) -> TestResult {
    guard let items = result.arrayValue, !items.isEmpty else {
        return TestResult(columns: ["Parameter", "Value"], rows: [])
    }

    var rows: [[String?]] = []
    var i = 0
    while i + 1 < items.count {
        rows.append([testRedisReplyToString(items[i]), testRedisReplyToString(items[i + 1])])
        i += 2
    }

    return TestResult(columns: ["Parameter", "Value"], rows: rows)
}

// MARK: - redisReplyToString

@Suite("Redis Result Building - redisReplyToString")
struct RedisReplyToStringTests {
    @Test("string returns the string")
    func stringCase() {
        #expect(testRedisReplyToString(.string("hello")) == "hello")
    }

    @Test("integer returns string representation")
    func integerCase() {
        #expect(testRedisReplyToString(.integer(42)) == "42")
    }

    @Test("data with valid UTF-8 returns the decoded string")
    func dataValidUtf8() {
        let data = Data("some text".utf8)
        #expect(testRedisReplyToString(.data(data)) == "some text")
    }

    @Test("data with invalid UTF-8 returns base64")
    func dataInvalidUtf8() {
        let data = Data([0xFF, 0xFE, 0x80])
        let expected = data.base64EncodedString()
        #expect(testRedisReplyToString(.data(data)) == expected)
    }

    @Test("null returns (nil)")
    func nullCase() {
        #expect(testRedisReplyToString(.null) == "(nil)")
    }

    @Test("status returns the status string")
    func statusCase() {
        #expect(testRedisReplyToString(.status("OK")) == "OK")
    }

    @Test("error returns the error string")
    func errorCase() {
        #expect(testRedisReplyToString(.error("ERR unknown")) == "ERR unknown")
    }

    @Test("array returns bracketed representation")
    func arrayCase() {
        let reply = TestRedisReply.array([.string("a"), .integer(1), .null])
        #expect(testRedisReplyToString(reply) == "[a, 1, (nil)]")
    }
}

// MARK: - Hash

@Suite("Redis Result Building - Hash")
struct RedisHashResultTests {
    @Test("hash with all string values")
    func allStrings() {
        let reply = TestRedisReply.array([
            .string("field1"), .string("value1"),
            .string("field2"), .string("value2")
        ])
        let result = buildTestHashResult(reply)
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == ["field1", "value1"])
        #expect(result.rows[1] == ["field2", "value2"])
    }

    @Test("hash with binary data values preserves all pairs")
    func binaryDataValues() {
        let binaryData = Data([0xFF, 0xFE])
        let reply = TestRedisReply.array([
            .string("field1"), .data(binaryData),
            .string("field2"), .string("value2")
        ])
        let result = buildTestHashResult(reply)
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == ["field1", binaryData.base64EncodedString()])
        #expect(result.rows[1] == ["field2", "value2"])
    }

    @Test("hash with null values shows (nil) instead of dropping")
    func nullValues() {
        let reply = TestRedisReply.array([
            .string("field1"), .null,
            .string("field2"), .string("value2")
        ])
        let result = buildTestHashResult(reply)
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == ["field1", "(nil)"])
        #expect(result.rows[1] == ["field2", "value2"])
    }

    @Test("hash with integer values shows string representation")
    func integerValues() {
        let reply = TestRedisReply.array([
            .string("field1"), .integer(42)
        ])
        let result = buildTestHashResult(reply)
        #expect(result.rows.count == 1)
        #expect(result.rows[0] == ["field1", "42"])
    }

    @Test("hash with empty array returns zero rows")
    func emptyArray() {
        let reply = TestRedisReply.array([])
        let result = buildTestHashResult(reply)
        #expect(result.rows.isEmpty)
    }

    @Test("hash with null reply returns zero rows")
    func nullReply() {
        let result = buildTestHashResult(.null)
        #expect(result.rows.isEmpty)
    }

    @Test("hash with odd number of elements ignores orphan")
    func oddElements() {
        let reply = TestRedisReply.array([
            .string("f1"), .string("v1"),
            .string("orphan")
        ])
        let result = buildTestHashResult(reply)
        #expect(result.rows.count == 1)
        #expect(result.rows[0] == ["f1", "v1"])
    }

    @Test("regression: stringArrayValue would corrupt hash with binary data")
    func regressionStringArrayValueCorruption() {
        // This is the core regression scenario. With the old code using stringArrayValue,
        // .data(non-UTF8) would be dropped, shifting "field2" into the value position of
        // field1, and "value2" would become an orphan key with no value.
        let binaryData = Data([0xFF, 0xFE])
        let reply = TestRedisReply.array([
            .string("field1"), .data(binaryData),
            .string("field2"), .string("value2")
        ])

        // Old (buggy) behavior: stringArrayValue drops the .data entry
        let buggyArray = reply.stringArrayValue
        // Would be ["field1", "field2", "value2"] — only 3 elements, pairs are misaligned
        #expect(buggyArray?.count == 3)
        #expect(buggyArray == ["field1", "field2", "value2"])

        // Fixed behavior: arrayValue + redisReplyToString preserves all entries
        let result = buildTestHashResult(reply)
        #expect(result.rows.count == 2)
        #expect(result.rows[0][0] == "field1")
        #expect(result.rows[0][1] == binaryData.base64EncodedString())
        #expect(result.rows[1] == ["field2", "value2"])
    }

    @Test("regression: stringArrayValue would corrupt hash with integer values")
    func regressionStringArrayValueIntegerDrop() {
        let reply = TestRedisReply.array([
            .string("counter"), .integer(100),
            .string("name"), .string("test")
        ])

        // Old (buggy) behavior: stringArrayValue drops .integer
        let buggyArray = reply.stringArrayValue
        #expect(buggyArray == ["counter", "name", "test"])

        // Fixed behavior: integer is converted to "100"
        let result = buildTestHashResult(reply)
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == ["counter", "100"])
        #expect(result.rows[1] == ["name", "test"])
    }
}

// MARK: - List

@Suite("Redis Result Building - List")
struct RedisListResultTests {
    @Test("list with all strings shows correct indices and values")
    func allStrings() {
        let reply = TestRedisReply.array([.string("a"), .string("b"), .string("c")])
        let result = buildTestListResult(reply)
        #expect(result.rows.count == 3)
        #expect(result.rows[0] == ["0", "a"])
        #expect(result.rows[1] == ["1", "b"])
        #expect(result.rows[2] == ["2", "c"])
    }

    @Test("list with binary data uses base64 fallback")
    func binaryData() {
        let data = Data([0xFF, 0xFE])
        let reply = TestRedisReply.array([.string("ok"), .data(data)])
        let result = buildTestListResult(reply)
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == ["0", "ok"])
        #expect(result.rows[1] == ["1", data.base64EncodedString()])
    }

    @Test("list with null entries shows (nil)")
    func nullEntries() {
        let reply = TestRedisReply.array([.string("a"), .null, .string("c")])
        let result = buildTestListResult(reply)
        #expect(result.rows.count == 3)
        #expect(result.rows[1] == ["1", "(nil)"])
    }

    @Test("list with offset starts indices from offset")
    func withOffset() {
        let reply = TestRedisReply.array([.string("x"), .string("y")])
        let result = buildTestListResult(reply, startOffset: 10)
        #expect(result.rows[0] == ["10", "x"])
        #expect(result.rows[1] == ["11", "y"])
    }

    @Test("list with integer entries shows string representation")
    func integerEntries() {
        let reply = TestRedisReply.array([.integer(1), .integer(2)])
        let result = buildTestListResult(reply)
        #expect(result.rows[0] == ["0", "1"])
        #expect(result.rows[1] == ["1", "2"])
    }

    @Test("list with null reply returns zero rows")
    func nullReply() {
        let result = buildTestListResult(.null)
        #expect(result.rows.isEmpty)
    }
}

// MARK: - Set

@Suite("Redis Result Building - Set")
struct RedisSetResultTests {
    @Test("set with all strings shows correct members")
    func allStrings() {
        let reply = TestRedisReply.array([.string("a"), .string("b"), .string("c")])
        let result = buildTestSetResult(reply)
        #expect(result.rows.count == 3)
        #expect(result.rows[0] == ["a"])
        #expect(result.rows[1] == ["b"])
        #expect(result.rows[2] == ["c"])
    }

    @Test("set with binary data uses base64 fallback")
    func binaryData() {
        let data = Data([0x80, 0x81])
        let reply = TestRedisReply.array([.string("ok"), .data(data)])
        let result = buildTestSetResult(reply)
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == ["ok"])
        #expect(result.rows[1] == [data.base64EncodedString()])
    }

    @Test("set with null and integer entries")
    func mixedTypes() {
        let reply = TestRedisReply.array([.null, .integer(7)])
        let result = buildTestSetResult(reply)
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == ["(nil)"])
        #expect(result.rows[1] == ["7"])
    }

    @Test("set with null reply returns zero rows")
    func nullReply() {
        let result = buildTestSetResult(.null)
        #expect(result.rows.isEmpty)
    }
}

// MARK: - Sorted Set

@Suite("Redis Result Building - Sorted Set")
struct RedisSortedSetResultTests {
    @Test("sorted set with scores shows correct member/score pairs")
    func withScores() {
        let reply = TestRedisReply.array([
            .string("alice"), .string("100"),
            .string("bob"), .string("200")
        ])
        let result = buildTestSortedSetResult(reply, withScores: true)
        #expect(result.columns == ["Member", "Score"])
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == ["alice", "100"])
        #expect(result.rows[1] == ["bob", "200"])
    }

    @Test("sorted set without scores shows just members")
    func withoutScores() {
        let reply = TestRedisReply.array([.string("alice"), .string("bob")])
        let result = buildTestSortedSetResult(reply, withScores: false)
        #expect(result.columns == ["Member"])
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == ["alice"])
        #expect(result.rows[1] == ["bob"])
    }

    @Test("sorted set with binary data members uses base64 fallback")
    func binaryDataMembers() {
        let data = Data([0xFF, 0xFE])
        let reply = TestRedisReply.array([
            .data(data), .string("50")
        ])
        let result = buildTestSortedSetResult(reply, withScores: true)
        #expect(result.rows.count == 1)
        #expect(result.rows[0] == [data.base64EncodedString(), "50"])
    }

    @Test("sorted set with integer scores")
    func integerScores() {
        let reply = TestRedisReply.array([
            .string("member"), .integer(99)
        ])
        let result = buildTestSortedSetResult(reply, withScores: true)
        #expect(result.rows.count == 1)
        #expect(result.rows[0] == ["member", "99"])
    }

    @Test("sorted set with null reply returns zero rows")
    func nullReply() {
        let result = buildTestSortedSetResult(.null, withScores: true)
        #expect(result.rows.isEmpty)
    }

    @Test("sorted set with odd elements and scores ignores orphan")
    func oddElementsWithScores() {
        let reply = TestRedisReply.array([
            .string("alice"), .string("100"),
            .string("orphan")
        ])
        let result = buildTestSortedSetResult(reply, withScores: true)
        #expect(result.rows.count == 1)
        #expect(result.rows[0] == ["alice", "100"])
    }
}

// MARK: - Config

@Suite("Redis Result Building - Config")
struct RedisConfigResultTests {
    @Test("config with all strings shows correct parameter/value pairs")
    func allStrings() {
        let reply = TestRedisReply.array([
            .string("maxmemory"), .string("0"),
            .string("timeout"), .string("300")
        ])
        let result = buildTestConfigResult(reply)
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == ["maxmemory", "0"])
        #expect(result.rows[1] == ["timeout", "300"])
    }

    @Test("config with empty array returns zero rows")
    func emptyArray() {
        let reply = TestRedisReply.array([])
        let result = buildTestConfigResult(reply)
        #expect(result.rows.isEmpty)
    }

    @Test("config with null reply returns zero rows")
    func nullReply() {
        let result = buildTestConfigResult(.null)
        #expect(result.rows.isEmpty)
    }

    @Test("config with integer values shows string representation")
    func integerValues() {
        let reply = TestRedisReply.array([
            .string("hz"), .integer(10)
        ])
        let result = buildTestConfigResult(reply)
        #expect(result.rows.count == 1)
        #expect(result.rows[0] == ["hz", "10"])
    }
}
