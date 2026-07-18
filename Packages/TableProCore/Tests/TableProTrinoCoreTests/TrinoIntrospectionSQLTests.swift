import XCTest
@testable import TableProTrinoCore

final class TrinoIntrospectionSQLTests: XCTestCase {
    func testQuoteIdentifierEscapesQuotes() {
        XCTAssertEqual(TrinoIntrospectionSQL.quoteIdentifier("name"), "\"name\"")
        XCTAssertEqual(TrinoIntrospectionSQL.quoteIdentifier("we\"ird"), "\"we\"\"ird\"")
    }

    func testQuoteLiteralEscapesApostrophes() {
        XCTAssertEqual(TrinoIntrospectionSQL.quoteLiteral("O'Brien"), "'O''Brien'")
    }

    func testQualifiedNameJoinsAvailableParts() {
        XCTAssertEqual(
            TrinoIntrospectionSQL.qualifiedName(catalog: "hive", schema: "sales", table: "orders"),
            "\"hive\".\"sales\".\"orders\""
        )
        XCTAssertEqual(
            TrinoIntrospectionSQL.qualifiedName(catalog: nil, schema: "sales", table: "orders"),
            "\"sales\".\"orders\""
        )
        XCTAssertEqual(
            TrinoIntrospectionSQL.qualifiedName(catalog: nil, schema: nil, table: "orders"),
            "\"orders\""
        )
    }

    func testShowCatalogsAndSchemas() {
        XCTAssertEqual(TrinoIntrospectionSQL.showCatalogs(), "SHOW CATALOGS")
        XCTAssertEqual(TrinoIntrospectionSQL.showSchemas(catalog: "hive"), "SHOW SCHEMAS FROM \"hive\"")
    }

    func testListTablesQueriesInformationSchema() {
        let sql = TrinoIntrospectionSQL.listTables(catalog: "hive", schema: "sales")
        XCTAssertTrue(sql.contains("\"hive\".information_schema.tables"))
        XCTAssertTrue(sql.contains("table_schema = 'sales'"))
        XCTAssertTrue(sql.contains("ORDER BY table_name"))
    }

    func testListColumnsQueriesInformationSchema() {
        let sql = TrinoIntrospectionSQL.listColumns(catalog: "hive", schema: "sales", table: "orders")
        XCTAssertTrue(sql.contains("\"hive\".information_schema.columns"))
        XCTAssertTrue(sql.contains("table_schema = 'sales'"))
        XCTAssertTrue(sql.contains("table_name = 'orders'"))
        XCTAssertTrue(sql.contains("ORDER BY ordinal_position"))
    }

    func testShowCreateTableAndView() {
        XCTAssertEqual(
            TrinoIntrospectionSQL.showCreateTable(catalog: "hive", schema: "sales", table: "orders"),
            "SHOW CREATE TABLE \"hive\".\"sales\".\"orders\""
        )
        XCTAssertEqual(
            TrinoIntrospectionSQL.showCreateView(catalog: "hive", schema: "sales", view: "v"),
            "SHOW CREATE VIEW \"hive\".\"sales\".\"v\""
        )
    }
}
