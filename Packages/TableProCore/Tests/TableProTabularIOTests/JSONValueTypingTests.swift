import Foundation
@testable import TableProTabularIO
import Testing

struct JSONValueTypingTests {
    @Test func testNumberCellsKeepAValidLexemeExactly() throws {
        for lexeme in ["1.0", "-0", "1e5", "12345678901234567890", "0.1", "1E+2", "-1.5e-3", "0"] {
            #expect(try JSONValueTyping.literal(for: lexeme, originalKind: .number) == lexeme)
            #expect(JSONValueTyping.isNumberLexeme(lexeme), "\(lexeme)")
        }
    }

    @Test func testNumberCellsTurnInvalidLexemesIntoStrings() throws {
        for text in ["01", "1.", "+1", ".5", " 1", "NaN", "Infinity", "0x10", "1e", "", "1,5", "--1"] {
            #expect(try JSONValueTyping.literal(for: text, originalKind: .number) == JSONText.stringLiteral(text))
            #expect(!JSONValueTyping.isNumberLexeme(text), "\(text)")
        }
    }

    @Test func testBooleanAndNullCellsKeepTheirKindOnlyForTheirLiterals() throws {
        #expect(try JSONValueTyping.literal(for: "false", originalKind: .boolean) == "false")
        #expect(try JSONValueTyping.literal(for: "True", originalKind: .boolean) == "\"True\"")
        #expect(try JSONValueTyping.literal(for: "null", originalKind: .null) == "null")
        #expect(try JSONValueTyping.literal(for: "", originalKind: .null) == "\"\"")
        #expect(try JSONValueTyping.literal(for: "1", originalKind: .boolean) == "\"1\"")
    }

    @Test func testTextAndMissingCellsAlwaysBecomeStrings() throws {
        for kind in [TabularCellKind.text, .missing, .error, .date] {
            #expect(try JSONValueTyping.literal(for: "42", originalKind: kind) == "\"42\"")
            #expect(try JSONValueTyping.literal(for: "true", originalKind: kind) == "\"true\"")
            #expect(try JSONValueTyping.literal(for: "null", originalKind: kind) == "\"null\"")
        }
    }

    @Test func testStringsAreEscaped() throws {
        #expect(try JSONValueTyping.literal(for: "a\"b\\c\n\r\t\u{08}\u{0C}\u{01}\u{1F}/é😀", originalKind: .text) == #""a\"b\\c\n\r\t\b\f\u0001\u001f/é😀""#)
    }

    @Test func testEscapedStringsReadBackToTheSameText() throws {
        let original = "quote \" backslash \\ tab \t newline \n control \u{07} emoji 👍🏽"
        let literal = try JSONValueTyping.literal(for: original, originalKind: .text)
        let bytes = Array("{\"k\":\(literal)}".utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            let layout = try JSONRowParser.parseObject(in: buffer, at: 0)
            #expect(JSONRowParser.cell(for: layout.members[0], in: buffer) == TabularCell(kind: .text, text: original))
        }
    }

    @Test func testContainerCellsMustBeValidJSONAndAreCompacted() throws {
        #expect(try JSONValueTyping.literal(for: "{ \"a\" : [1, 2], \"s\": \"x y\" }", originalKind: .object) == #"{"a":[1,2],"s":"x y"}"#)
        #expect(try JSONValueTyping.literal(for: "[\n  1,\n  2\n]", originalKind: .array) == "[1,2]")
        #expect(try JSONValueTyping.literal(for: " 7 ", originalKind: .array) == "7")
        #expect(try JSONValueTyping.literal(for: "\"text\"", originalKind: .object) == "\"text\"")
    }

    @Test func testInvalidContainerTextThrows() {
        let cases: [(String, TabularCellKind, Int)] = [
            ("{\"a\":}", .object, 5),
            ("[1,", .array, 3),
            ("", .object, 0),
            ("hello", .array, 0),
            ("[1] x", .array, 4)
        ]
        for (text, kind, offset) in cases {
            if let error = #expect(throws: (any Error).self, "\(text)", performing: { try JSONValueTyping.literal(for: text, originalKind: kind) }) {
                #expect(error as? JSONValueTypingError == .invalidJSON(kind: kind, byteOffset: offset), "\(text)")
            }
        }
    }
}
