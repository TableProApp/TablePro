//
//  JsonReindenterTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("JsonReindenter")
struct JsonReindenterTests {
    @Test("Reindent preserves original key order")
    func reindentPreservesKeyOrder() throws {
        let input = "{\"z\":1,\"a\":2,\"m\":3}"
        let result = JsonReindenter.reindent(input)
        let zRange = try #require(result.range(of: "\"z\""))
        let aRange = try #require(result.range(of: "\"a\""))
        let mRange = try #require(result.range(of: "\"m\""))
        #expect(zRange.lowerBound < aRange.lowerBound)
        #expect(aRange.lowerBound < mRange.lowerBound)
    }

    @Test("Reindent preserves large integer precision")
    func reindentPreservesLargeInteger() {
        let input = "{\"id\":9007199254740993}"
        let result = JsonReindenter.reindent(input)
        #expect(result.contains("9007199254740993"))
    }

    @Test("Reindent preserves high-precision decimal token")
    func reindentPreservesDecimalToken() {
        let input = "{\"value\":3.141592653589793238}"
        let result = JsonReindenter.reindent(input)
        #expect(result.contains("3.141592653589793238"))
    }

    @Test("Reindent handles top-level primitives")
    func reindentTopLevelPrimitives() {
        #expect(JsonReindenter.reindent("\"hello\"") == "\"hello\"")
        #expect(JsonReindenter.reindent("42") == "42")
        #expect(JsonReindenter.reindent("true") == "true")
        #expect(JsonReindenter.reindent("null") == "null")
        #expect(JsonReindenter.reindent("  -3.5e10  ") == "-3.5e10")
    }

    @Test("Reindent formats top-level array")
    func reindentTopLevelArray() {
        let expected = """
        [
          1,
          2,
          3
        ]
        """
        #expect(JsonReindenter.reindent("[1,2,3]") == expected)
    }

    @Test("Reindent formats empty containers inline")
    func reindentEmptyContainers() {
        #expect(JsonReindenter.reindent("{}") == "{}")
        #expect(JsonReindenter.reindent("[]") == "[]")
        #expect(JsonReindenter.reindent("{\"a\":{},\"b\":[]}") == "{\n  \"a\": {},\n  \"b\": []\n}")
    }

    @Test("Reindent passes invalid JSON through unchanged")
    func reindentInvalidPassthrough() {
        let input = "not json {"
        #expect(JsonReindenter.reindent(input) == input)
        #expect(JsonReindenter.reindentIfValid(input) == nil)
    }

    @Test("Reindent rejects trailing garbage")
    func reindentTrailingGarbage() {
        #expect(JsonReindenter.reindentIfValid("{\"a\":1} extra") == nil)
    }

    @Test("Reindent is idempotent")
    func reindentIdempotent() {
        let input = "{\"a\":[1,{\"b\":2}],\"c\":\"x\"}"
        let once = JsonReindenter.reindent(input)
        let twice = JsonReindenter.reindent(once)
        #expect(once == twice)
    }

    @Test("Reindent preserves escaped string contents byte for byte")
    func reindentPreservesEscapes() {
        let input = "{\"path\":\"a\\/b\",\"emoji\":\"\\uD83D\\uDE00\"}"
        let result = JsonReindenter.reindent(input)
        #expect(result.contains("\"a\\/b\""))
        #expect(result.contains("\"\\uD83D\\uDE00\""))
    }

    @Test("Reindent does not split braces inside strings")
    func reindentBracesInStrings() {
        let input = "{\"text\":\"{not:structure}\"}"
        let result = JsonReindenter.reindent(input)
        #expect(result == "{\n  \"text\": \"{not:structure}\"\n}")
    }

    @Test("Normalize strips insignificant whitespace")
    func normalizeStripsWhitespace() {
        let input = "{\n  \"a\": 1,\n  \"b\": [ 2, 3 ]\n}"
        #expect(JsonReindenter.normalize(input) == "{\"a\":1,\"b\":[2,3]}")
    }

    @Test("Normalize is equal across pretty and compact forms")
    func normalizeEquivalence() {
        let compact = "{\"a\":1,\"b\":2}"
        let pretty = JsonReindenter.reindent(compact)
        #expect(JsonReindenter.normalize(compact) == JsonReindenter.normalize(pretty))
    }

    @Test("Normalize preserves key order and large integers")
    func normalizePreservesOrderAndPrecision() {
        let input = "{ \"z\": 9007199254740993, \"a\": 2 }"
        #expect(JsonReindenter.normalize(input) == "{\"z\":9007199254740993,\"a\":2}")
    }

    @Test("Oversized input is returned unchanged")
    func sizeCap() {
        let big = "{\"a\":\"" + String(repeating: "x", count: 500_001) + "\"}"
        #expect(JsonReindenter.reindentIfValid(big) == nil)
        #expect(JsonReindenter.reindent(big) == big)
        #expect(JsonReindenter.normalize(big) == big)
    }

    @Test("decodeStringLiteral decodes escapes and surrogate pairs")
    func decodeStringLiteral() {
        #expect(JsonSyntaxParser.decodeStringLiteral("\"a\\/b\"") == "a/b")
        #expect(JsonSyntaxParser.decodeStringLiteral("\"line\\nbreak\"") == "line\nbreak")
        #expect(JsonSyntaxParser.decodeStringLiteral("\"\\u0041\"") == "A")
        #expect(JsonSyntaxParser.decodeStringLiteral("\"\\uD83D\\uDE00\"") == "😀")
    }

    @Test("Deeply nested JSON is rejected instead of overflowing the stack")
    func deepNestingDoesNotCrash() {
        let depth = 20_000
        let deep = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(JsonReindenter.reindentIfValid(deep) == nil)
        #expect(JsonReindenter.reindent(deep) == deep)
        #expect(JsonReindenter.normalize(deep) == deep)
    }
}
