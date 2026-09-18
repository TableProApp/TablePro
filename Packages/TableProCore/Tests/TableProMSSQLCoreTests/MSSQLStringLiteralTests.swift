@testable import TableProMSSQLCore
import XCTest

final class MSSQLStringLiteralTests: XCTestCase {
    func testQuotedPrefixesWithN() {
        XCTAssertEqual(MSSQLStringLiteral.quoted("plain"), "N'plain'")
    }

    func testQuotedKeepsNonAsciiText() {
        XCTAssertEqual(MSSQLStringLiteral.quoted("日本語メール"), "N'日本語メール'")
    }

    func testQuotedDoublesSingleQuotes() {
        XCTAssertEqual(MSSQLStringLiteral.quoted("O'Brien"), "N'O''Brien'")
        XCTAssertEqual(MSSQLStringLiteral.quoted("'; DROP TABLE t --"), "N'''; DROP TABLE t --'")
    }

    func testQuotedHandlesEmptyString() {
        XCTAssertEqual(MSSQLStringLiteral.quoted(""), "N''")
    }

    func testEscapedReturnsBodyWithoutQuotes() {
        XCTAssertEqual(MSSQLStringLiteral.escaped("O'Brien"), "O''Brien")
        XCTAssertEqual(MSSQLStringLiteral.escaped("plain"), "plain")
    }

    func testLikePatternWrapsWildcardsInsideTheLiteral() {
        XCTAssertEqual(
            MSSQLStringLiteral.likePattern("メール", prefixWildcard: true, suffixWildcard: true),
            "N'%メール%' ESCAPE '\\'"
        )
        XCTAssertEqual(
            MSSQLStringLiteral.likePattern("abc", prefixWildcard: false, suffixWildcard: true),
            "N'abc%' ESCAPE '\\'"
        )
        XCTAssertEqual(
            MSSQLStringLiteral.likePattern("abc", prefixWildcard: true, suffixWildcard: false),
            "N'%abc' ESCAPE '\\'"
        )
    }

    func testLikePatternEscapesUserWildcards() {
        XCTAssertEqual(
            MSSQLStringLiteral.likePattern("50%_off", prefixWildcard: true, suffixWildcard: true),
            "N'%50\\%\\_off%' ESCAPE '\\'"
        )
    }

    /// `[` opens a character class in T-SQL and in no other engine this app speaks to, so a
    /// filter for `a[bc]` matched `ab` and `ac` and never the text the user typed.
    func testLikePatternEscapesBracketWildcards() {
        XCTAssertEqual(
            MSSQLStringLiteral.likePattern("a[bc]", prefixWildcard: true, suffixWildcard: true),
            "N'%a\\[bc]%' ESCAPE '\\'"
        )
    }

    func testLikePatternEscapesBackslashBeforeWildcards() {
        XCTAssertEqual(
            MSSQLStringLiteral.likePattern("a\\b", prefixWildcard: false, suffixWildcard: false),
            "N'a\\\\b' ESCAPE '\\'"
        )
    }

    func testLikePatternDoublesSingleQuotes() {
        XCTAssertEqual(
            MSSQLStringLiteral.likePattern("O'Brien", prefixWildcard: true, suffixWildcard: true),
            "N'%O''Brien%' ESCAPE '\\'"
        )
    }

    func testLikeConditionCoversTheFourPatternOperators() {
        XCTAssertEqual(
            MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "CONTAINS", value: "日本"),
            "[n] LIKE N'%日本%' ESCAPE '\\'"
        )
        XCTAssertEqual(
            MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "NOT CONTAINS", value: "日本"),
            "[n] NOT LIKE N'%日本%' ESCAPE '\\'"
        )
        XCTAssertEqual(
            MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "STARTS WITH", value: "日本"),
            "[n] LIKE N'日本%' ESCAPE '\\'"
        )
        XCTAssertEqual(
            MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "ENDS WITH", value: "日本"),
            "[n] LIKE N'%日本' ESCAPE '\\'"
        )
    }

    func testLikeConditionLeavesOtherOperatorsToTheSharedBuilder() {
        XCTAssertNil(MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "=", value: "x"))
        XCTAssertNil(MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "IN", value: "a,b"))
        XCTAssertNil(MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "IS NULL", value: ""))
        XCTAssertNil(MSSQLStringLiteral.likeCondition(quotedColumn: "[n]", op: "REGEX", value: "x"))
    }
}
