import Foundation
import TableProPluginKit
import Testing

@Suite("DynamoDB JSON")
struct DynamoDBJSONTests {
    struct NumberCase: Sendable, CustomTestStringConvertible {
        let literal: String
        var testDescription: String { literal }
    }

    struct MalformedCase: Sendable, CustomTestStringConvertible {
        let name: String
        let text: String
        var testDescription: String { name }
    }

    @Test("An object with nested arrays, literals and strings parses into the matching tree")
    func parsesObject() throws {
        let json = try DynamoDBJSON.parse(#"{ "a" : 1, "b" : [true, false, null, "x"], "c" : {} }"#)
        #expect(json == .object([
            "a": .number("1"),
            "b": .array([.bool(true), .bool(false), .null, .string("x")]),
            "c": .object([:])
        ]))
    }

    @Test("A top-level array and an empty array parse")
    func parsesArrays() throws {
        #expect(try DynamoDBJSON.parse("[]") == .array([]))
        #expect(try DynamoDBJSON.parse(" [ [1], [\"a\"] ] ") == .array([.array([.number("1")]), .array([.string("a")])]))
    }

    @Test("String escapes decode to the characters they name")
    func decodesEscapes() throws {
        let json = try DynamoDBJSON.parse(#""line\nbreak \"quoted\" back\\slash \/ tab\t café""#)
        #expect(json == .string("line\nbreak \"quoted\" back\\slash / tab\t caf\u{00E9}"))
    }

    @Test("A surrogate pair escape decodes to one scalar outside the basic plane")
    func decodesSurrogatePair() throws {
        let json = try DynamoDBJSON.parse(#""😀""#)
        #expect(json == .string("\u{1F600}"))
        #expect(json.stringValue?.unicodeScalars.count == 1)
    }

    @Test("A lone surrogate escape is rejected", arguments: [#""\ud83d""#, #""\ud83dx""#, #""\ude00""#])
    func rejectsLoneSurrogate(text: String) {
        #expect(throws: DynamoDBJSON.ParseError.self) { try DynamoDBJSON.parse(text) }
    }

    @Test("An unknown escape and a raw control character are rejected", arguments: [#""\x""#, "\"a\u{01}b\""])
    func rejectsBadStringContent(text: String) {
        #expect(throws: DynamoDBJSON.ParseError.self) { try DynamoDBJSON.parse(text) }
    }

    @Test(
        "A number keeps the exact text it was written with",
        arguments: [
            NumberCase(literal: "12345678901234567890123456789012345678"),
            NumberCase(literal: "1.50"),
            NumberCase(literal: "-0"),
            NumberCase(literal: "1e-130"),
            NumberCase(literal: "9.9999999999999999999999999999999999999E+125"),
            NumberCase(literal: "0.000")
        ]
    )
    func keepsNumberText(number: NumberCase) throws {
        #expect(try DynamoDBJSON.parse(number.literal) == .number(number.literal))
        let wrapped = try DynamoDBJSON.parse("{\"n\":\(number.literal)}")
        #expect(wrapped["n"]?.numberText == number.literal)
    }

    @Test("Text that is not a JSON number is rejected", arguments: ["01", "+1", ".5", "1.", "1e", "-", "NaN", "0x10"])
    func rejectsNonJSONNumbers(text: String) {
        #expect(throws: DynamoDBJSON.ParseError.self) { try DynamoDBJSON.parse(text) }
    }

    @Test("A key that appears twice in one object is rejected")
    func rejectsDuplicateKey() {
        #expect(throws: DynamoDBJSON.ParseError.duplicateKey("a")) {
            try DynamoDBJSON.parse(#"{"a": 1, "b": 2, "a": 3}"#)
        }
    }

    @Test("The same key in two different objects is not a duplicate")
    func allowsKeyInSiblingObjects() throws {
        let json = try DynamoDBJSON.parse(#"[{"a": 1}, {"a": 2}]"#)
        #expect(json == .array([.object(["a": .number("1")]), .object(["a": .number("2")])]))
    }

    @Test("Text after the document is rejected with its position")
    func rejectsTrailingText() {
        #expect(throws: DynamoDBJSON.ParseError.trailingText(offset: 8)) {
            try DynamoDBJSON.parse(#"{"a":1} x"#)
        }
        #expect(throws: DynamoDBJSON.ParseError.trailingText(offset: 3)) {
            try DynamoDBJSON.parse("[1][2]")
        }
    }

    @Test("Whitespace around the document is allowed")
    func allowsSurroundingWhitespace() throws {
        #expect(try DynamoDBJSON.parse("\n\t {\"a\": true} \r\n") == .object(["a": .bool(true)]))
    }

    @Test(
        "Malformed documents are rejected",
        arguments: [
            MalformedCase(name: "empty", text: ""),
            MalformedCase(name: "unclosed object", text: #"{"a": 1"#),
            MalformedCase(name: "unclosed array", text: "[1, 2"),
            MalformedCase(name: "unclosed string", text: #""abc"#),
            MalformedCase(name: "unquoted key", text: "{a: 1}"),
            MalformedCase(name: "trailing comma", text: "[1, 2,]"),
            MalformedCase(name: "misspelled literal", text: "tru"),
            MalformedCase(name: "missing colon", text: #"{"a" 1}"#)
        ]
    )
    func rejectsMalformed(malformed: MalformedCase) {
        #expect(throws: DynamoDBJSON.ParseError.self) { try DynamoDBJSON.parse(malformed.text) }
    }

    @Test("Data that is not UTF-8 is rejected")
    func rejectsInvalidUTF8() {
        #expect(throws: DynamoDBJSON.ParseError.self) { try DynamoDBJSON.parse(Data([0x22, 0xFF, 0xFE, 0x22])) }
    }

    @Test("A document nested 32 levels deep parses")
    func parsesDynamoDBNestingDepth() throws {
        let text = String(repeating: #"{"a":"#, count: 32) + "1" + String(repeating: "}", count: 32)
        var json = try DynamoDBJSON.parse(text)
        for _ in 0..<32 {
            json = try #require(json["a"])
        }
        #expect(json == .number("1"))
    }

    @Test("A document nested far past the limit is rejected as too deep")
    func rejectsExcessiveNesting() {
        let text = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        #expect(throws: DynamoDBJSON.ParseError.tooDeep) { try DynamoDBJSON.parse(text) }
    }

    @Test("A Scan page holding an item nested as deeply as DynamoDB allows parses")
    func parsesResponseAtDynamoDBNestingLimit() throws {
        var attribute = #"{"S":"leaf"}"#
        for _ in 0..<31 {
            attribute = #"{"M":{"child":"# + attribute + "}}"
        }
        let response = #"{"Count":1,"Items":[{"pk":{"S":"a"},"deep":"# + attribute + "}]}"
        let json = try DynamoDBJSON.parse(response)
        let items = try #require(json["Items"]?.arrayValue)
        let item = try DynamoDBItem(wireItem: try #require(items.first))
        var value = try #require(item["deep"])
        for _ in 0..<31 {
            guard case .map(let entries) = value else {
                Issue.record("Expected a map, got \(value)")
                return
            }
            value = try #require(entries["child"])
        }
        #expect(value == .string("leaf"))
    }

    @Test("parsePrefix returns the value and the text after it")
    func parsePrefixReturnsRemainder() throws {
        let result = try DynamoDBJSON.parsePrefix(#"  {"a": [1, 2]} WHERE "pk" = 'x'"#)
        #expect(result.value == .object(["a": .array([.number("1"), .number("2")])]))
        #expect(result.remainder == #" WHERE "pk" = 'x'"#)
    }

    @Test("parsePrefix of a complete document leaves no remainder")
    func parsePrefixOfWholeDocument() throws {
        let result = try DynamoDBJSON.parsePrefix("[1]")
        #expect(result.value == .array([.number("1")]))
        #expect(result.remainder.isEmpty)
    }

    @Test("parsePrefix keeps text that follows directly after the value")
    func parsePrefixKeepsAdjacentText() throws {
        let result = try DynamoDBJSON.parsePrefix(#""café"rest"#)
        #expect(result.value == .string("caf\u{00E9}"))
        #expect(result.remainder == "rest")
    }

    @Test("parsePrefix rejects text that does not start with JSON")
    func parsePrefixRejectsNonJSON() {
        #expect(throws: DynamoDBJSON.ParseError.self) { try DynamoDBJSON.parsePrefix("WHERE x = 1") }
    }

    @Test("Serialized output sorts object keys at every level")
    func serializedSortsKeys() {
        let json = DynamoDBJSON.object([
            "b": .number("2"),
            "a": .object(["z": .bool(true), "y": .null]),
            "c": .array([.string("x")])
        ])
        #expect(json.serialized() == #"{"a":{"y":null,"z":true},"b":2,"c":["x"]}"#)
    }

    @Test("Serialized output writes numbers exactly as they were given")
    func serializedWritesNumbersVerbatim() {
        let json = DynamoDBJSON.array([
            .number("12345678901234567890123456789012345678"),
            .number("1.50"),
            .number("-0"),
            .number("1e-130"),
            .number("1E+125")
        ])
        #expect(json.serialized() == "[12345678901234567890123456789012345678,1.50,-0,1e-130,1E+125]")
    }

    @Test("Serialized output escapes quotes, backslashes and control characters")
    func serializedEscapesStrings() {
        let json = DynamoDBJSON.string("a\"b\\c\nd\u{01}")
        #expect(json.serialized() == #""a\"b\\c\nd\u0001""#)
    }

    @Test("Serialized output parses back to the same value")
    func serializedRoundTrips() throws {
        let json = Self.sample
        #expect(try DynamoDBJSON.parse(json.serialized()) == json)
        #expect(try DynamoDBJSON.parse(json.serializedData) == json)
    }

    @Test("Pretty output spans several lines and parses back to the same value")
    func prettyOutputRoundTrips() throws {
        let json = Self.sample
        let pretty = json.serialized(pretty: true)
        #expect(pretty.contains("\n"))
        #expect(try DynamoDBJSON.parse(pretty) == json)
    }

    @Test("Accessors return the payload of their own case only")
    func accessorsMatchTheirCase() {
        #expect(DynamoDBJSON.number("42").intValue == 42)
        #expect(DynamoDBJSON.number("1.5").doubleValue == 1.5)
        #expect(DynamoDBJSON.string("42").intValue == nil)
        #expect(DynamoDBJSON.string("x").numberText == nil)
        #expect(DynamoDBJSON.bool(true).boolValue == true)
        #expect(DynamoDBJSON.null.boolValue == nil)
        #expect(DynamoDBJSON.array([]).objectValue == nil)
        #expect(DynamoDBJSON.array([.null])["key"] == nil)
    }

    private static let sample = DynamoDBJSON.object([
        "text": .string("quote \" backslash \\ newline \n caf\u{00E9} \u{1F600}"),
        "big": .number("12345678901234567890123456789012345678"),
        "scaled": .number("1.50"),
        "tiny": .number("1e-130"),
        "negative zero": .number("-0"),
        "flags": .array([.bool(true), .bool(false), .null]),
        "nested": .object(["empty object": .object([:]), "empty array": .array([])])
    ])
}
