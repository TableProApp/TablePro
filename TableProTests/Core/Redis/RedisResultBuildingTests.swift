//
//  RedisResultBuildingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Redis Result Building - displayText")
struct RedisReplyDisplayTextTests {
    @Test("string returns the string")
    func stringCase() {
        #expect(RedisReply.string("hello").displayText == "hello")
    }

    @Test("integer returns string representation")
    func integerCase() {
        #expect(RedisReply.integer(42).displayText == "42")
    }

    @Test("data with valid UTF-8 returns the decoded string")
    func dataValidUtf8() {
        #expect(RedisReply.data(Data("some text".utf8)).displayText == "some text")
    }

    @Test("data with invalid UTF-8 returns base64")
    func dataInvalidUtf8() {
        let data = Data([0xFF, 0xFE, 0x80])
        #expect(RedisReply.data(data).displayText == data.base64EncodedString())
    }

    @Test("null returns (nil)")
    func nullCase() {
        #expect(RedisReply.null.displayText == "(nil)")
    }

    @Test("status returns the status string")
    func statusCase() {
        #expect(RedisReply.status("OK").displayText == "OK")
    }

    @Test("error is marked the way redis-cli marks it")
    func errorCase() {
        #expect(RedisReply.error("ERR unknown").displayText == "(error) ERR unknown")
    }

    @Test("array returns bracketed representation")
    func arrayCase() {
        let reply = RedisReply.array([.string("a"), .integer(1), .null])
        #expect(reply.displayText == "[a, 1, (nil)]")
    }

    @Test("a nested array marks the errors inside it")
    func nestedArrayMarksErrors() {
        let reply = RedisReply.array([.string("a"), .array([.integer(1), .error("WRONGTYPE x")])])
        #expect(reply.displayText == "[a, [1, (error) WRONGTYPE x]]")
    }
}

@Suite("Redis Result Building - Hash")
struct RedisHashResultTests {
    @Test("hash with all string values")
    func allStrings() {
        let grid = RedisReplyGrid.hash(.array([
            .string("field1"), .string("value1"),
            .string("field2"), .string("value2")
        ]))
        #expect(grid.columns == ["Field", "Value"])
        #expect(grid.columnTypeNames == ["String", "String"])
        #expect(grid.rows == [["field1", "value1"], ["field2", "value2"]])
    }

    @Test("hash with binary data values preserves all pairs")
    func binaryDataValues() {
        let binaryData = Data([0xFF, 0xFE])
        let grid = RedisReplyGrid.hash(.array([
            .string("field1"), .data(binaryData),
            .string("field2"), .string("value2")
        ]))
        #expect(grid.rows == [["field1", .text(binaryData.base64EncodedString())], ["field2", "value2"]])
    }

    @Test("hash with null values shows (nil) instead of dropping")
    func nullValues() {
        let grid = RedisReplyGrid.hash(.array([
            .string("field1"), .null,
            .string("field2"), .string("value2")
        ]))
        #expect(grid.rows == [["field1", "(nil)"], ["field2", "value2"]])
    }

    @Test("hash with integer values shows string representation")
    func integerValues() {
        let grid = RedisReplyGrid.hash(.array([.string("field1"), .integer(42)]))
        #expect(grid.rows == [["field1", "42"]])
    }

    @Test("hash with empty array returns zero rows")
    func emptyArray() {
        let grid = RedisReplyGrid.hash(.array([]))
        #expect(grid.rows.isEmpty)
        #expect(grid.columns == ["Field", "Value"])
    }

    @Test("hash with null reply returns zero rows")
    func nullReply() {
        #expect(RedisReplyGrid.hash(.null).rows.isEmpty)
    }

    @Test("hash with odd number of elements ignores orphan")
    func oddElements() {
        let grid = RedisReplyGrid.hash(.array([.string("f1"), .string("v1"), .string("orphan")]))
        #expect(grid.rows == [["f1", "v1"]])
    }

    @Test("stringArrayValue drops binary entries, and the hash grid keeps every pair")
    func binaryEntriesKeepTheirPairs() {
        let binaryData = Data([0xFF, 0xFE])
        let reply = RedisReply.array([
            .string("field1"), .data(binaryData),
            .string("field2"), .string("value2")
        ])

        #expect(reply.stringArrayValue == ["field1", "field2", "value2"])

        let grid = RedisReplyGrid.hash(reply)
        #expect(grid.rows == [["field1", .text(binaryData.base64EncodedString())], ["field2", "value2"]])
    }

    @Test("stringArrayValue drops integer entries, and the hash grid keeps every pair")
    func integerEntriesKeepTheirPairs() {
        let reply = RedisReply.array([
            .string("counter"), .integer(100),
            .string("name"), .string("test")
        ])

        #expect(reply.stringArrayValue == ["counter", "name", "test"])

        let grid = RedisReplyGrid.hash(reply)
        #expect(grid.rows == [["counter", "100"], ["name", "test"]])
    }
}

@Suite("Redis Result Building - List")
struct RedisListResultTests {
    @Test("list with all strings shows correct indices and values")
    func allStrings() {
        let grid = RedisReplyGrid.list(.array([.string("a"), .string("b"), .string("c")]), startOffset: 0)
        #expect(grid.columns == ["Index", "Value"])
        #expect(grid.columnTypeNames == ["Int64", "String"])
        #expect(grid.rows == [["0", "a"], ["1", "b"], ["2", "c"]])
    }

    @Test("list with binary data uses base64 fallback")
    func binaryData() {
        let data = Data([0xFF, 0xFE])
        let grid = RedisReplyGrid.list(.array([.string("ok"), .data(data)]), startOffset: 0)
        #expect(grid.rows == [["0", "ok"], ["1", .text(data.base64EncodedString())]])
    }

    @Test("list with null entries shows (nil)")
    func nullEntries() {
        let grid = RedisReplyGrid.list(.array([.string("a"), .null, .string("c")]), startOffset: 0)
        #expect(grid.rows == [["0", "a"], ["1", "(nil)"], ["2", "c"]])
    }

    @Test("list with offset starts indices from offset")
    func withOffset() {
        let grid = RedisReplyGrid.list(.array([.string("x"), .string("y")]), startOffset: 10)
        #expect(grid.rows == [["10", "x"], ["11", "y"]])
    }

    @Test("list with integer entries shows string representation")
    func integerEntries() {
        let grid = RedisReplyGrid.list(.array([.integer(1), .integer(2)]), startOffset: 0)
        #expect(grid.rows == [["0", "1"], ["1", "2"]])
    }

    @Test("list with null reply returns zero rows")
    func nullReply() {
        let grid = RedisReplyGrid.list(.null, startOffset: 0)
        #expect(grid.rows.isEmpty)
        #expect(grid.columnTypeNames == ["Int64", "String"])
    }
}

@Suite("Redis Result Building - Set")
struct RedisSetResultTests {
    @Test("set with all strings shows correct members")
    func allStrings() {
        let grid = RedisReplyGrid.set(.array([.string("a"), .string("b"), .string("c")]))
        #expect(grid.columns == ["Member"])
        #expect(grid.columnTypeNames == ["String"])
        #expect(grid.rows == [["a"], ["b"], ["c"]])
    }

    @Test("set with binary data uses base64 fallback")
    func binaryData() {
        let data = Data([0x80, 0x81])
        let grid = RedisReplyGrid.set(.array([.string("ok"), .data(data)]))
        #expect(grid.rows == [["ok"], [.text(data.base64EncodedString())]])
    }

    @Test("set with null and integer entries")
    func mixedTypes() {
        let grid = RedisReplyGrid.set(.array([.null, .integer(7)]))
        #expect(grid.rows == [["(nil)"], ["7"]])
    }

    @Test("set with null reply returns zero rows")
    func nullReply() {
        #expect(RedisReplyGrid.set(.null).rows.isEmpty)
    }
}

@Suite("Redis Result Building - Sorted Set")
struct RedisSortedSetResultTests {
    @Test("sorted set with scores shows correct member/score pairs")
    func withScores() {
        let grid = RedisReplyGrid.sortedSet(.array([
            .string("alice"), .string("100"),
            .string("bob"), .string("200")
        ]), withScores: true)
        #expect(grid.columns == ["Member", "Score"])
        #expect(grid.columnTypeNames == ["String", "Double"])
        #expect(grid.rows == [["alice", "100"], ["bob", "200"]])
    }

    @Test("sorted set without scores shows just members")
    func withoutScores() {
        let grid = RedisReplyGrid.sortedSet(.array([.string("alice"), .string("bob")]), withScores: false)
        #expect(grid.columns == ["Member"])
        #expect(grid.columnTypeNames == ["String"])
        #expect(grid.rows == [["alice"], ["bob"]])
    }

    @Test("sorted set with binary data members uses base64 fallback")
    func binaryDataMembers() {
        let data = Data([0xFF, 0xFE])
        let grid = RedisReplyGrid.sortedSet(.array([.data(data), .string("50")]), withScores: true)
        #expect(grid.rows == [[.text(data.base64EncodedString()), "50"]])
    }

    @Test("sorted set with integer scores")
    func integerScores() {
        let grid = RedisReplyGrid.sortedSet(.array([.string("member"), .integer(99)]), withScores: true)
        #expect(grid.rows == [["member", "99"]])
    }

    @Test("sorted set with null reply returns zero rows")
    func nullReply() {
        let grid = RedisReplyGrid.sortedSet(.null, withScores: true)
        #expect(grid.rows.isEmpty)
        #expect(grid.columns == ["Member", "Score"])
    }

    @Test("sorted set with odd elements and scores ignores orphan")
    func oddElementsWithScores() {
        let grid = RedisReplyGrid.sortedSet(.array([
            .string("alice"), .string("100"),
            .string("orphan")
        ]), withScores: true)
        #expect(grid.rows == [["alice", "100"]])
    }
}

@Suite("Redis Result Building - Stream")
struct RedisStreamGridTests {
    @Test("each XRANGE entry becomes its ID and its fields")
    func entriesBecomeRows() {
        let grid = RedisReplyGrid.stream(.array([
            .array([.string("1-0"), .array([.string("f1"), .string("v1"), .string("f2"), .string("v2")])]),
            .array([.string("2-0"), .array([.string("only"), .integer(3)])])
        ]))
        #expect(grid.columns == ["ID", "Fields"])
        #expect(grid.columnTypeNames == ["String", "String"])
        #expect(grid.rows == [["1-0", "f1=v1, f2=v2"], ["2-0", "only=3"]])
    }

    @Test("an entry that is not an ID and a field list is skipped")
    func malformedEntryIsSkipped() {
        let grid = RedisReplyGrid.stream(.array([
            .string("garbage"),
            .array([.string("1-0")]),
            .array([.string("2-0"), .string("not a field list")]),
            .array([.string("3-0"), .array([.string("f"), .string("v")])])
        ]))
        #expect(grid.rows == [["3-0", "f=v"]])
    }

    @Test("a reply that is not an array returns zero rows")
    func nullReply() {
        #expect(RedisReplyGrid.stream(.null).rows.isEmpty)
    }
}

@Suite("Redis Result Building - Config")
struct RedisConfigResultTests {
    @Test("config with all strings shows correct parameter/value pairs")
    func allStrings() {
        let grid = RedisReplyGrid.config(.array([
            .string("maxmemory"), .string("0"),
            .string("timeout"), .string("300")
        ]))
        #expect(grid.columns == ["Parameter", "Value"])
        #expect(grid.columnTypeNames == ["String", "String"])
        #expect(grid.rows == [["maxmemory", "0"], ["timeout", "300"]])
    }

    @Test("config with empty array returns zero rows")
    func emptyArray() {
        #expect(RedisReplyGrid.config(.array([])).rows.isEmpty)
    }

    @Test("config with null reply returns zero rows")
    func nullReply() {
        #expect(RedisReplyGrid.config(.null).rows.isEmpty)
    }

    @Test("config with integer values shows string representation")
    func integerValues() {
        let grid = RedisReplyGrid.config(.array([.string("hz"), .integer(10)]))
        #expect(grid.rows == [["hz", "10"]])
    }
}

@Suite("Redis Result Building - Generic")
struct RedisGenericGridTests {
    @Test("an integer reply is typed Int64")
    func integerReply() {
        let grid = RedisReplyGrid.generic(.integer(7))
        #expect(grid.columns == ["result"])
        #expect(grid.columnTypeNames == ["Int64"])
        #expect(grid.rows == [["7"]])
    }

    @Test("a status reply is one text row")
    func statusReply() {
        let grid = RedisReplyGrid.generic(.status("OK"))
        #expect(grid.columnTypeNames == ["String"])
        #expect(grid.rows == [["OK"]])
    }

    @Test("an array reply is one row per element, with the errors inside it marked")
    func arrayReply() {
        let grid = RedisReplyGrid.generic(.array([
            .status("OK"),
            .error("WRONGTYPE Operation against a key holding the wrong kind of value"),
            .integer(2),
            .null
        ]))
        #expect(grid.columnTypeNames == ["String"])
        #expect(grid.rows == [
            ["OK"],
            ["(error) WRONGTYPE Operation against a key holding the wrong kind of value"],
            ["2"],
            ["(nil)"]
        ])
    }

    @Test("a top-level error is its bare message")
    func errorReply() {
        #expect(RedisReplyGrid.generic(.error("ERR unknown")).rows == [["ERR unknown"]])
    }

    @Test("a null reply reads (nil)")
    func nullReply() {
        #expect(RedisReplyGrid.generic(.null).rows == [["(nil)"]])
    }

    @Test("binary data that is not UTF-8 reads as base64")
    func binaryReply() {
        let data = Data([0xFF, 0x00, 0xFE])
        #expect(RedisReplyGrid.generic(.data(data)).rows == [[.text(data.base64EncodedString())]])
    }

    @Test("the query result carries the grid and affects no rows")
    func queryResultCarriesTheGrid() {
        let grid = RedisReplyGrid.generic(.array([.string("a"), .string("b")]))
        let result = grid.queryResult(startTime: Date())
        #expect(result.columns == grid.columns)
        #expect(result.columnTypeNames == grid.columnTypeNames)
        #expect(result.rows == grid.rows)
        #expect(result.rowsAffected == 0)
        #expect(result.executionTime >= 0)
    }
}
