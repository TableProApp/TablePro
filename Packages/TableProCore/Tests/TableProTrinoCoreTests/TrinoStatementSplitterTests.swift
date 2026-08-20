import XCTest
@testable import TableProTrinoCore

final class TrinoStatementSplitterTests: XCTestCase {
    func testSingleStatementNoTrailingSemicolon() {
        XCTAssertEqual(TrinoStatementSplitter.split("SELECT 1"), ["SELECT 1"])
    }

    func testSingleStatementTrailingSemicolon() {
        XCTAssertEqual(TrinoStatementSplitter.split("SELECT 1;"), ["SELECT 1"])
    }

    func testSplitsTwoStatements() {
        XCTAssertEqual(
            TrinoStatementSplitter.split("ALTER TABLE t RENAME COLUMN a TO b;\nALTER TABLE t ALTER COLUMN b SET DATA TYPE bigint"),
            ["ALTER TABLE t RENAME COLUMN a TO b", "ALTER TABLE t ALTER COLUMN b SET DATA TYPE bigint"]
        )
    }

    func testIgnoresSemicolonInsideSingleQuotes() {
        XCTAssertEqual(TrinoStatementSplitter.split("SELECT 'a;b'"), ["SELECT 'a;b'"])
    }

    func testIgnoresSemicolonInsideDoubleQuotedIdentifier() {
        XCTAssertEqual(TrinoStatementSplitter.split("SELECT \"we;ird\" FROM t"), ["SELECT \"we;ird\" FROM t"])
    }

    func testHandlesEscapedSingleQuote() {
        XCTAssertEqual(TrinoStatementSplitter.split("SELECT 'O''Brien;x'; SELECT 2"), ["SELECT 'O''Brien;x'", "SELECT 2"])
    }

    func testIgnoresSemicolonInLineComment() {
        XCTAssertEqual(TrinoStatementSplitter.split("SELECT 1 -- a;b\n; SELECT 2"), ["SELECT 1 -- a;b", "SELECT 2"])
    }

    func testIgnoresSemicolonInBlockComment() {
        XCTAssertEqual(TrinoStatementSplitter.split("SELECT 1 /* a;b */; SELECT 2"), ["SELECT 1 /* a;b */", "SELECT 2"])
    }

    func testDropsEmptyStatements() {
        XCTAssertEqual(TrinoStatementSplitter.split(";;SELECT 1;;"), ["SELECT 1"])
    }

    func testDropsTrailingCommentOnlySegment() {
        XCTAssertEqual(TrinoStatementSplitter.split("SELECT 1; -- done"), ["SELECT 1"])
    }

    func testDropsCommentOnlyInput() {
        XCTAssertEqual(TrinoStatementSplitter.split("-- just a comment"), [])
        XCTAssertEqual(TrinoStatementSplitter.split("/* block */"), [])
    }

    func testKeepsTrailingCommentOnRealStatement() {
        XCTAssertEqual(TrinoStatementSplitter.split("SELECT 1 -- trailing"), ["SELECT 1 -- trailing"])
    }

    func testKeepsLeadingCommentWithFollowingStatement() {
        XCTAssertEqual(TrinoStatementSplitter.split("SELECT 1;\n-- note\nSELECT 2"), ["SELECT 1", "-- note\nSELECT 2"])
    }
}
