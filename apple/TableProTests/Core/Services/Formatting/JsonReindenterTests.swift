import Foundation
import Testing

@testable import TablePro

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

    @Test("Input past the editor's two million characters is returned unchanged")
    func sizeCap() {
        let big = "{\"a\":\"" + String(repeating: "x", count: 2_000_001) + "\"}"
        #expect(JsonReindenter.reindentIfValid(big) == nil)
        #expect(JsonReindenter.reindent(big) == big)
        #expect(JsonReindenter.normalize(big) == big)
    }

    @Test("A value over half a million characters is indented and compacted")
    func valueInTheBandIsLaidOut() throws {
        let value = String(repeating: "x", count: 600_000)
        let source = "{\"a\":\"\(value)\",\"b\":[1,2]}"
        let pretty = try #require(JsonReindenter.reindentIfValid(source))

        #expect(pretty == "{\n  \"a\": \"\(value)\",\n  \"b\": [\n    1,\n    2\n  ]\n}")
        #expect(JsonReindenter.normalize(pretty) == source)
    }

    // `{"a":"…"}` indents to its content plus 13 characters.
    @Test("The cap counts the indented text in UTF-16 units", arguments: [
        ("x", 1_999_987, true), ("x", 1_999_988, false),
        ("\u{E9}", 1_999_987, true), ("\u{E9}", 1_999_988, false),
        ("\u{1F600}", 999_993, true), ("\u{1F600}", 999_994, false),
    ])
    func capCountsTheIndentedText(character: String, count: Int, fits: Bool) {
        let source = "{\"a\":\"" + String(repeating: character, count: count) + "\"}"
        let pretty = JsonReindenter.reindentIfValid(source)

        #expect((pretty != nil) == fits)
        if let pretty {
            #expect((pretty as NSString).length <= 2_000_000)
        }
    }

    @Test("A value whose indented text passes the cap stays on its line but still compacts")
    func indentedTextPastTheCap() {
        let elements = Array(repeating: "1", count: 600_000)
        let source = "[" + elements.joined(separator: ", ") + "]"
        #expect((source as NSString).length < 2_000_000)

        #expect(JsonReindenter.reindentIfValid(source) == nil)
        #expect(JsonReindenter.reindent(source) == source)
        #expect(JsonReindenter.normalize(source) == "[" + elements.joined(separator: ",") + "]")
    }

    @Test("The writer lays out what the syntax parser's tree lays out, indented and compact")
    func writerMatchesTheParsersTree() {
        for source in Self.corpus {
            #expect(JsonReindenter.reindentIfValid(source) == ReferenceLayout.pretty(source), "\(source.debugDescription)")
            #expect(JsonReindenter.normalize(source) == ReferenceLayout.compact(source), "\(source.debugDescription)")
        }
    }

    private static let truncated = #"{"a":[1,-2.5e-3,{"b":"x\"y\\"}],"c":true,"d":null,"é":"😀","e":{}}"#

    private static let corpus: [String] = {
        var corpus = [
            #"{"z":1,"a":2,"m":3}"#, #"{"id":9007199254740993}"#, #"{"value":3.141592653589793238}"#,
            #""hello""#, "42", "true", "false", "null", "  -3.5e10  ", "[1,2,3]", "{}", "[]", #"{"a":{},"b":[]}"#,
            "not json {", #"{"a":1} extra"#, #"{"a":[1,{"b":2}],"c":"x"}"#, #"{"path":"a\/b","emoji":"\uD83D\uDE00"}"#,
            #"{"text":"{not:structure}"}"#, "{\n  \"a\": 1,\n  \"b\": [ 2, 3 ]\n}", #"{ "z": 9007199254740993, "a": 2 }"#,
            #""a\"b\\c\n""#, #"["\u0041", "\t", "\/"]"#, #""\uD800""#, #""\uDC00x""#, #"["\uD83D", "\uDE00"]"#,
            #""\é""#, #""a\😀b""#, #""\é"#, #""\"#, #""\""#, #""\\""#,
            "007", "-0", "1.", ".5", "-", "1e", "1e+", "1E-2", "01.10e+05", "--1", "+1", "1.2.3", "1e5e5", "-01",
            "tru", "nul", "nulll", "[true,false,null]", "[truefalse]", #"{"a":nul}"#,
            "\t{\r\n\"a\"\t:\n1}\n", "\u{00A0}1", "1\u{00A0}", "\u{FEFF}{}",
            #"{"名前":"値","emoji":"👩‍💻","flag":"🇻🇳"}"#, "[\"e\u{301}\", \"\u{0600}1\"]",
            "{,}", #"{"a":1,}"#, "[1,]", "[,1]", #"{"a"}"#, #"{"a":}"#, "{1:2}", "]", "}", "", " ", #""""#, "\"", #"""x"#,
            "[[]]", "[{},[]]", #"{"a":[{"b":[{}]}]}"#, "[ [ ] , { } ]", #"{"a" : 1 , "b" : [ ] }"#,
        ]
        for depth in [511, 512, 513] {
            corpus.append(String(repeating: "[", count: depth) + String(repeating: "]", count: depth))
            corpus.append(String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth))
            corpus.append(String(repeating: "[1,", count: depth) + "2" + String(repeating: "]", count: depth))
        }
        let scalars = Array(truncated.unicodeScalars)
        for length in 0...scalars.count {
            var prefix = String.UnicodeScalarView()
            prefix.append(contentsOf: scalars[0..<length])
            corpus.append(String(prefix))
        }
        let loneSurrogates: [unichar] = [0x5B, 0x22, 0xD800, 0x22, 0x2C, 0x22, 0x61, 0xDC00, 0x22, 0x5D]
        corpus.append(NSString(characters: loneSurrogates, length: loneSurrogates.count) as String)
        return corpus
    }()

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

// The layout over `JsonSyntaxParser`'s node tree that the byte writer replaced.
private enum ReferenceLayout {
    static func pretty(_ source: String) -> String? {
        guard let node = JsonSyntaxParser.parse(source) else { return nil }
        var output = ""
        writePretty(node, into: &output, depth: 0)
        return output
    }

    static func compact(_ source: String) -> String {
        guard let node = JsonSyntaxParser.parse(source) else { return source }
        var output = ""
        writeCompact(node, into: &output)
        return output
    }

    private static func writePretty(_ node: JsonSyntaxNode, into output: inout String, depth: Int) {
        switch node {
        case .string(let raw), .number(let raw), .literal(let raw):
            output += raw
        case .object(let pairs):
            guard !pairs.isEmpty else {
                output += "{}"
                return
            }
            output += "{\n"
            let childPad = String(repeating: "  ", count: depth + 1)
            for (offset, pair) in pairs.enumerated() {
                output += childPad + pair.key + ": "
                writePretty(pair.value, into: &output, depth: depth + 1)
                output += offset == pairs.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: "  ", count: depth) + "}"
        case .array(let elements):
            guard !elements.isEmpty else {
                output += "[]"
                return
            }
            output += "[\n"
            let childPad = String(repeating: "  ", count: depth + 1)
            for (offset, element) in elements.enumerated() {
                output += childPad
                writePretty(element, into: &output, depth: depth + 1)
                output += offset == elements.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: "  ", count: depth) + "]"
        }
    }

    private static func writeCompact(_ node: JsonSyntaxNode, into output: inout String) {
        switch node {
        case .string(let raw), .number(let raw), .literal(let raw):
            output += raw
        case .object(let pairs):
            output += "{"
            for (offset, pair) in pairs.enumerated() {
                output += pair.key + ":"
                writeCompact(pair.value, into: &output)
                if offset != pairs.count - 1 { output += "," }
            }
            output += "}"
        case .array(let elements):
            output += "["
            for (offset, element) in elements.enumerated() {
                writeCompact(element, into: &output)
                if offset != elements.count - 1 { output += "," }
            }
            output += "]"
        }
    }
}
