import XCTest
@testable import TableProTeradataCore

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
}
