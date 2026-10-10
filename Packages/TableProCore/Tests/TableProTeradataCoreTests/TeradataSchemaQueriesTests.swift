@testable import TableProTeradataCore
import XCTest

final class TeradataSchemaQueriesTests: XCTestCase {
    func testQuoteIdentifierDoublesInternalQuotes() {
        XCTAssertEqual(TeradataSchemaQueries.quoteIdentifier("Sales"), "\"Sales\"")
        XCTAssertEqual(TeradataSchemaQueries.quoteIdentifier("My\"Col"), "\"My\"\"Col\"")
    }

    func testQualifiedName() {
        XCTAssertEqual(TeradataSchemaQueries.qualifiedName(database: "Retail", table: "Orders"),
                       "\"Retail\".\"Orders\"")
        XCTAssertEqual(TeradataSchemaQueries.qualifiedName(database: nil, table: "Orders"), "\"Orders\"")
        XCTAssertEqual(TeradataSchemaQueries.qualifiedName(database: "", table: "Orders"), "\"Orders\"")
    }

    func testListTablesUsesLiteralDatabase() {
        let sql = TeradataSchemaQueries.listTables(database: "Re'tail")
        XCTAssertTrue(sql.contains("FROM DBC.TablesV"))
        XCTAssertTrue(sql.contains("DatabaseName = 'Re''tail'"))
    }

    func testListTablesExcludesProceduresMacrosAndFunctions() {
        let sql = TeradataSchemaQueries.listTables(database: "demo_user")
        XCTAssertTrue(sql.contains("TableKind IN ('T', 'O', 'Q', 'V')"))
        for kind in ["'M'", "'P'", "'E'", "'F'", "'R'", "'G'"] {
            XCTAssertFalse(sql.contains(kind), "browsable-object list must not include \(kind)")
        }
    }

    func testBrowseFirstPageUsesTop() {
        let sql = TeradataSchemaQueries.browse(
            database: "Retail", table: "Orders", columns: nil,
            sortColumns: [], limit: 100, offset: 0)
        XCTAssertEqual(sql, "SELECT TOP 100 * FROM \"Retail\".\"Orders\"")
    }

    func testBrowseFirstPageWithSort() {
        let sql = TeradataSchemaQueries.browse(
            database: "Retail", table: "Orders", columns: nil,
            sortColumns: [("Total", false)], limit: 50, offset: 0)
        XCTAssertEqual(sql, "SELECT TOP 50 * FROM \"Retail\".\"Orders\" ORDER BY \"Total\" DESC")
    }

    func testBrowseOffsetPageUsesQualifyRowNumber() {
        let sql = TeradataSchemaQueries.browse(
            database: "Retail", table: "Orders", columns: ["Id", "Total"],
            sortColumns: [("Id", true)], limit: 100, offset: 200)
        XCTAssertEqual(sql,
                       "SELECT \"Id\", \"Total\" FROM \"Retail\".\"Orders\" "
                           + "QUALIFY ROW_NUMBER() OVER (ORDER BY \"Id\" ASC) BETWEEN 201 AND 300")
    }

    func testBrowseOffsetPageFallsBackToOrderByOne() {
        let sql = TeradataSchemaQueries.browse(
            database: nil, table: "Orders", columns: nil,
            sortColumns: [], limit: 25, offset: 25)
        XCTAssertTrue(sql.contains("QUALIFY ROW_NUMBER() OVER (ORDER BY 1) BETWEEN 26 AND 50"))
    }

    func testColumnsQueryTargetsColumnsV() {
        let sql = TeradataSchemaQueries.columns(database: "Retail", table: "Orders")
        XCTAssertTrue(sql.contains("FROM DBC.ColumnsV"))
        XCTAssertTrue(sql.contains("ORDER BY ColumnId"))
        XCTAssertTrue(sql.contains("TableName = 'Orders'"))
    }

    func testStatisticsRowCountReadsTableStatsV() {
        let sql = TeradataSchemaQueries.statisticsRowCount(database: "Re'tail", table: "Orders")
        XCTAssertEqual(
            sql,
            "SELECT CAST(MAX(RowCount) AS BIGINT) FROM DBC.TableStatsV WHERE DatabaseName = 'Re''tail' AND TableName = 'Orders'"
        )
    }

    func testTableCommentReadsCommentStringFromTablesV() {
        let sql = TeradataSchemaQueries.tableComment(database: "Re'tail", table: "Orders")
        XCTAssertEqual(
            sql,
            "SELECT CommentString FROM DBC.TablesV WHERE DatabaseName = 'Re''tail' AND TableName = 'Orders'"
        )
    }

    func testCommentStatementSetsAndClearsTableAndViewComments() {
        let target = TeradataSchemaQueries.qualifiedName(database: "Retail", table: "Orders")
        XCTAssertEqual(
            TeradataSchemaQueries.commentStatement(objectType: "TABLE", qualifiedName: target, comment: "it's"),
            "COMMENT ON TABLE \"Retail\".\"Orders\" IS 'it''s'"
        )
        XCTAssertEqual(
            TeradataSchemaQueries.commentStatement(objectType: "VIEW", qualifiedName: target, comment: "x"),
            "COMMENT ON VIEW \"Retail\".\"Orders\" IS 'x'"
        )
        XCTAssertEqual(
            TeradataSchemaQueries.commentStatement(objectType: "TABLE", qualifiedName: target, comment: nil),
            "COMMENT ON TABLE \"Retail\".\"Orders\" IS ''"
        )
        XCTAssertEqual(
            TeradataSchemaQueries.commentStatement(objectType: "VIEW", qualifiedName: target, comment: ""),
            "COMMENT ON VIEW \"Retail\".\"Orders\" IS ''"
        )
    }

    func testCommentStatementRefusesKindsTeradataCannotComment() {
        for kind in ["MATERIALIZED VIEW", "SEQUENCE", "SYSTEM TABLE", "FOREIGN TABLE"] {
            XCTAssertNil(TeradataSchemaQueries.commentStatement(objectType: kind, qualifiedName: "\"t\"", comment: nil), kind)
        }
    }

    func testColumnCommentStatementsSkipColumnsWithoutAComment() {
        let statements = TeradataSchemaQueries.columnCommentStatements(
            qualifiedTable: "\"Retail\".\"Orders\"",
            comments: [(column: "Id", comment: nil), (column: "Total", comment: "net's"), (column: "Note", comment: "")]
        )
        XCTAssertEqual(statements, ["COMMENT ON COLUMN \"Retail\".\"Orders\".\"Total\" IS 'net''s'"])
    }

    func testQuotesSurviveAFollowingCombiningMark() {
        XCTAssertEqual(TeradataSchemaQueries.quoteLiteral("a'\u{0301}b"), "'a''\u{0301}b'")
        XCTAssertEqual(TeradataSchemaQueries.quoteIdentifier("a\"\u{0301}b"), "\"a\"\"\u{0301}b\"")
    }
}
