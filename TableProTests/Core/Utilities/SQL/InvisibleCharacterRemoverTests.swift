//
//  InvisibleCharacterRemoverTests.swift
//  TableProTests
//

import CodeEditTextView
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Remove invisible characters")
struct InvisibleCharacterRemoverTests {
    private func clean(
        _ text: String,
        scope: NSRange? = nil,
        dialect: SqlDialect = .mysql,
        lineEnding: String = "\n"
    ) -> String {
        let nsText = text as NSString
        let range = scope ?? NSRange(location: 0, length: nsText.length)
        let replacements = InvisibleCharacterRemover.replacements(
            in: nsText,
            scope: range,
            skippingLiteralsAndComments: scope == nil,
            dialect: dialect,
            lineEnding: lineEnding
        )
        let result = NSMutableString(string: text)
        for replacement in replacements.reversed() {
            result.replaceCharacters(in: replacement.range, with: replacement.string)
        }
        return result as String
    }

    @Test("The reported statement runs clean")
    func reportedStatement() {
        #expect(clean("\u{8}SELECT *\nFROM t\nWHERE c LIKE '%乐%';") == "SELECT *\nFROM t\nWHERE c LIKE '%乐%';")
    }

    @Test("Zero-width and control characters are removed")
    func removesMarkers() {
        #expect(clean("SEL\u{200B}ECT\u{FEFF} 1\u{7F}") == "SELECT 1")
    }

    @Test("Special spaces become ordinary spaces")
    func normalizesSpaces() {
        #expect(clean("SELECT\u{A0}*\u{3000}FROM\u{202F}t") == "SELECT * FROM t")
    }

    @Test("Form feed and vertical tab become spaces, so the tokens either side stay apart")
    func whitespaceControlsBecomeSpaces() {
        #expect(clean("SELECT\u{C}1\u{B}AS x") == "SELECT 1 AS x")
    }

    @Test("Line and paragraph separators become the document's line ending")
    func separatorsBecomeLineEndings() {
        #expect(clean("SELECT 1\u{2028}FROM t") == "SELECT 1\nFROM t")
        #expect(clean("SELECT 1\u{2029}FROM t", lineEnding: "\r\n") == "SELECT 1\r\nFROM t")
    }

    @Test("Without a selection, string literals, identifiers and comments keep their characters")
    func literalsAndCommentsAreKept() {
        let text = "SELECT\u{A0}'张\u{3000}三', `a\u{200B}b` -- x\u{A0}y\nFROM t /* \u{8} */"
        #expect(clean(text) == "SELECT '张\u{3000}三', `a\u{200B}b` -- x\u{A0}y\nFROM t /* \u{8} */")
    }

    @Test("A PostgreSQL dollar-quoted body is kept")
    func dollarQuotedBodyIsKept() {
        let text = "SELECT\u{A0}$$a\u{A0}b$$"
        #expect(clean(text, dialect: .postgres) == "SELECT $$a\u{A0}b$$")
    }

    @Test("A MySQL conditional comment runs, so it is cleaned like code")
    func conditionalCommentIsCode() {
        #expect(clean("/*!40101 SET\u{A0}NAMES utf8 */") == "/*!40101 SET NAMES utf8 */")
        #expect(clean("/* a\u{A0}b */") == "/* a\u{A0}b */")
    }

    @Test("A MySQL hash comment is kept")
    func hashCommentIsKept() {
        #expect(clean("SELECT\u{A0}1 # a\u{A0}b") == "SELECT 1 # a\u{A0}b")
    }

    @Test("An explicit selection is cleaned even inside a literal")
    func selectionReachesInsideLiterals() {
        let text = "SELECT '张\u{3000}三'"
        let literal = (text as NSString).range(of: "张\u{3000}三")
        #expect(clean(text, scope: literal) == "SELECT '张 三'")
    }

    @Test("Emoji sequences, variation selectors and Persian joiners are kept")
    func scriptJoinersAreKept() {
        let text = "SELECT '\u{1F468}\u{200D}\u{1F469}', '\u{2764}\u{FE0F}', '\u{0645}\u{06CC}\u{200C}\u{062E}'"
        let literal = NSRange(location: 0, length: (text as NSString).length)
        #expect(clean(text, scope: literal) == text)
    }

    @Test("Tag characters used to smuggle text are removed, and a subdivision flag is kept")
    func tagCharacters() {
        let flag = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        let text = "SELECT\u{E0041}\u{E0042} '\(flag)'"
        let whole = NSRange(location: 0, length: (text as NSString).length)
        #expect(clean(text, scope: whole) == "SELECT '\(flag)'")
    }

    @Test("Nothing to remove produces no edits")
    func cleanTextHasNoEdits() {
        let text = "SELECT * FROM t WHERE c = '乐'" as NSString
        let replacements = InvisibleCharacterRemover.replacements(
            in: text,
            scope: NSRange(location: 0, length: text.length),
            skippingLiteralsAndComments: true,
            dialect: .mysql,
            lineEnding: "\n"
        )
        #expect(replacements.isEmpty)
    }

    @Test("The caret follows the text it sat next to")
    func caretMapping() {
        let text = "\u{8}SEL\u{200B}ECT 1" as NSString
        let replacements = InvisibleCharacterRemover.replacements(
            in: text,
            scope: NSRange(location: 0, length: text.length),
            skippingLiteralsAndComments: true,
            dialect: .mysql,
            lineEnding: "\n"
        )
        #expect(InvisibleCharacterRemover.mappedOffset(0, through: replacements) == 0)
        #expect(InvisibleCharacterRemover.mappedOffset(4, through: replacements) == 3)
        #expect(InvisibleCharacterRemover.mappedOffset(6, through: replacements) == 4)
        #expect(InvisibleCharacterRemover.mappedOffset(text.length, through: replacements) == text.length - 2)
    }
}
