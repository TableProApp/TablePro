import Foundation
@testable import TableProDatabase
import Testing

struct SQLEscapingTests {
    @Test("A driver with no session rule doubles a quote a combining mark follows and drops NUL")
    func defaultEscaperSeesCombiningMark() {
        let escaped = MockDatabaseDriver().escapeStringLiteral("x'\u{301} OR 1=1 --\0")
        #expect(Array(escaped.unicodeScalars) == Array("x''\u{301} OR 1=1 --".unicodeScalars))
    }

    @Test("The backslash escaper doubles a backslash a combining mark follows, so it cannot escape the quote")
    func backslashEscaperSeesCombiningMark() {
        let escaped = SQLEscaping.backslashStringLiteral("a\\\u{301}' OR 1=1 --")
        #expect(Array(escaped.unicodeScalars) == Array("a\\\\\u{301}'' OR 1=1 --".unicodeScalars))
    }

    @Test("The backslash escaper writes control characters as MySQL escapes")
    func backslashEscaperWritesControlCharacters() {
        #expect(SQLEscaping.backslashStringLiteral("a\0b\nc\r\td\u{1A}") == #"a\0b\nc\r\td\Z"#)
    }

    @Test("The ANSI escaper leaves a backslash alone")
    func ansiEscaperLeavesBackslash() {
        #expect(SQLEscaping.ansiStringLiteral(#"a\'b"#) == #"a\''b"#)
    }
}
