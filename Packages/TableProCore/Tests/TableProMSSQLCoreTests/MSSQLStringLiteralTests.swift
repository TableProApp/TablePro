import Foundation
@testable import TableProMSSQLCore
import Testing

struct MSSQLStringLiteralTests {
    @Test func testQuotedPrefixesWithN() {
        #expect(MSSQLStringLiteral.quoted("plain") == "N'plain'")
    }

    @Test func testQuotedKeepsNonAsciiText() {
        #expect(MSSQLStringLiteral.quoted("日本語メール") == "N'日本語メール'")
    }

    @Test func testQuotedDoublesSingleQuotes() {
        #expect(MSSQLStringLiteral.quoted("O'Brien") == "N'O''Brien'")
        #expect(MSSQLStringLiteral.quoted("'; DROP TABLE t --") == "N'''; DROP TABLE t --'")
    }

    @Test func testQuotedHandlesEmptyString() {
        #expect(MSSQLStringLiteral.quoted("") == "N''")
    }

    @Test func testEscapedReturnsBodyWithoutQuotes() {
        #expect(MSSQLStringLiteral.escaped("O'Brien") == "O''Brien")
        #expect(MSSQLStringLiteral.escaped("plain") == "plain")
    }

    @Test func testLikePatternWrapsWildcardsInsideTheLiteral() {
        #expect(MSSQLStringLiteral.likePattern("メール", prefixWildcard: true, suffixWildcard: true) == "N'%メール%' ESCAPE '\\'")
        #expect(MSSQLStringLiteral.likePattern("abc", prefixWildcard: false, suffixWildcard: true) == "N'abc%' ESCAPE '\\'")
        #expect(MSSQLStringLiteral.likePattern("abc", prefixWildcard: true, suffixWildcard: false) == "N'%abc' ESCAPE '\\'")
    }

    @Test func testLikePatternEscapesUserWildcards() {
        #expect(MSSQLStringLiteral.likePattern("50%_off", prefixWildcard: true, suffixWildcard: true) == "N'%50\\%\\_off%' ESCAPE '\\'")
    }

    /// `[` opens a character class in T-SQL and in no other engine this app speaks to, so a
    /// filter for `a[bc]` matched `ab` and `ac` and never the text the user typed.
    @Test func testLikePatternEscapesBracketWildcards() {
        #expect(MSSQLStringLiteral.likePattern("a[bc]", prefixWildcard: true, suffixWildcard: true) == "N'%a\\[bc]%' ESCAPE '\\'")
    }

    @Test func testLikePatternEscapesBackslashBeforeWildcards() {
        #expect(MSSQLStringLiteral.likePattern("a\\b", prefixWildcard: false, suffixWildcard: false) == "N'a\\\\b' ESCAPE '\\'")
    }

    @Test func testLikePatternDoublesSingleQuotes() {
        #expect(MSSQLStringLiteral.likePattern("O'Brien", prefixWildcard: true, suffixWildcard: true) == "N'%O''Brien%' ESCAPE '\\'")
    }

    @Test func testLikeConditionCoversTheFourPatternOperators() {
        #expect(MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "CONTAINS", value: "日本") == "[n] LIKE N'%日本%' ESCAPE '\\'")
        #expect(MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "NOT CONTAINS", value: "日本") == "[n] NOT LIKE N'%日本%' ESCAPE '\\'")
        #expect(MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "STARTS WITH", value: "日本") == "[n] LIKE N'日本%' ESCAPE '\\'")
        #expect(MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "ENDS WITH", value: "日本") == "[n] LIKE N'%日本' ESCAPE '\\'")
    }

    @Test func testLikeConditionLeavesOtherOperatorsToTheSharedBuilder() {
        #expect(MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "=", value: "x") == nil)
        #expect(MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "IN", value: "a,b") == nil)
        #expect(MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "IS NULL", value: "") == nil)
        #expect(MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "REGEX", value: "x") == nil)
    }

    /// A default `replacingOccurrences` matches whole grapheme clusters, so an apostrophe followed by a combining or
    /// format mark was left single and ended the literal early.
    @Test func testApostropheBeforeCombiningMarkIsDoubled() {
        #expect(MSSQLStringLiteral.escaped("a'\u{301}b") == "a''\u{301}b")
    }

    @Test func testApostropheBeforeZeroWidthJoinerIsDoubled() {
        #expect(MSSQLStringLiteral.quoted("a'\u{200D}b") == "N'a''\u{200D}b'")
    }

    @Test func testLikeWildcardBeforeCombiningMarkIsEscaped() {
        #expect(MSSQLStringLiteral.escapeForLike("5%\u{301}") == "5\\%\u{301}")
        #expect(MSSQLStringLiteral.escapeForLike("a_\u{200D}[\u{301}") == "a\\_\u{200D}\\[\u{301}")
    }
}
