import Foundation
@testable import TableProTabularIO
import XCTest

final class JSONValueTypingTests: XCTestCase {
    func testNumberCellsKeepAValidLexemeExactly() throws {
        for lexeme in ["1.0", "-0", "1e5", "12345678901234567890", "0.1", "1E+2", "-1.5e-3", "0"] {
            XCTAssertEqual(try JSONValueTyping.literal(for: lexeme, originalKind: .number), lexeme)
            XCTAssertTrue(JSONValueTyping.isNumberLexeme(lexeme), lexeme)
        }
    }

    func testNumberCellsTurnInvalidLexemesIntoStrings() throws {
        for text in ["01", "1.", "+1", ".5", " 1", "NaN", "Infinity", "0x10", "1e", "", "1,5", "--1"] {
            XCTAssertEqual(try JSONValueTyping.literal(for: text, originalKind: .number), JSONText.stringLiteral(text))
            XCTAssertFalse(JSONValueTyping.isNumberLexeme(text), text)
        }
    }

    func testBooleanAndNullCellsKeepTheirKindOnlyForTheirLiterals() throws {
        XCTAssertEqual(try JSONValueTyping.literal(for: "false", originalKind: .boolean), "false")
        XCTAssertEqual(try JSONValueTyping.literal(for: "True", originalKind: .boolean), "\"True\"")
        XCTAssertEqual(try JSONValueTyping.literal(for: "null", originalKind: .null), "null")
        XCTAssertEqual(try JSONValueTyping.literal(for: "", originalKind: .null), "\"\"")
        XCTAssertEqual(try JSONValueTyping.literal(for: "1", originalKind: .boolean), "\"1\"")
    }

    func testTextAndMissingCellsAlwaysBecomeStrings() throws {
        for kind in [TabularCellKind.text, .missing, .error, .date] {
            XCTAssertEqual(try JSONValueTyping.literal(for: "42", originalKind: kind), "\"42\"")
            XCTAssertEqual(try JSONValueTyping.literal(for: "true", originalKind: kind), "\"true\"")
            XCTAssertEqual(try JSONValueTyping.literal(for: "null", originalKind: kind), "\"null\"")
        }
    }

    func testStringsAreEscaped() throws {
        XCTAssertEqual(
            try JSONValueTyping.literal(for: "a\"b\\c\n\r\t\u{08}\u{0C}\u{01}\u{1F}/é😀", originalKind: .text),
            #""a\"b\\c\n\r\t\b\f\u0001\u001f/é😀""#
        )
    }

    func testEscapedStringsReadBackToTheSameText() throws {
        let original = "quote \" backslash \\ tab \t newline \n control \u{07} emoji 👍🏽"
        let literal = try JSONValueTyping.literal(for: original, originalKind: .text)
        let bytes = Array("{\"k\":\(literal)}".utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            let layout = try JSONRowParser.parseObject(in: buffer, at: 0)
            XCTAssertEqual(JSONRowParser.cell(for: layout.members[0], in: buffer), TabularCell(kind: .text, text: original))
        }
    }

    func testContainerCellsMustBeValidJSONAndAreCompacted() throws {
        XCTAssertEqual(try JSONValueTyping.literal(for: "{ \"a\" : [1, 2], \"s\": \"x y\" }", originalKind: .object), #"{"a":[1,2],"s":"x y"}"#)
        XCTAssertEqual(try JSONValueTyping.literal(for: "[\n  1,\n  2\n]", originalKind: .array), "[1,2]")
        XCTAssertEqual(try JSONValueTyping.literal(for: " 7 ", originalKind: .array), "7")
        XCTAssertEqual(try JSONValueTyping.literal(for: "\"text\"", originalKind: .object), "\"text\"")
    }

    func testInvalidContainerTextThrows() {
        let cases: [(String, TabularCellKind, Int)] = [
            ("{\"a\":}", .object, 5),
            ("[1,", .array, 3),
            ("", .object, 0),
            ("hello", .array, 0),
            ("[1] x", .array, 4)
        ]
        for (text, kind, offset) in cases {
            XCTAssertThrowsError(try JSONValueTyping.literal(for: text, originalKind: kind), text) { error in
                XCTAssertEqual(error as? JSONValueTypingError, .invalidJSON(kind: kind, byteOffset: offset), text)
            }
        }
    }
}
