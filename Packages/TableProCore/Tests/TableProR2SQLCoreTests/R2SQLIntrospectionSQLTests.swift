import XCTest
@testable import TableProR2SQLCore

final class R2SQLIntrospectionSQLTests: XCTestCase {
    func testShowNamespaces() {
        XCTAssertEqual(R2SQLIntrospectionSQL.showNamespaces(), "SHOW NAMESPACES")
    }

    func testShowTablesQuotesNamespace() {
        XCTAssertEqual(R2SQLIntrospectionSQL.showTables(namespace: "analytics"), "SHOW TABLES IN \"analytics\"")
    }

    func testDescribeQualifiesNamespaceAndTable() {
        XCTAssertEqual(
            R2SQLIntrospectionSQL.describe(namespace: "analytics", table: "events"),
            "DESCRIBE \"analytics\".\"events\""
        )
    }

    func testDottedNamespaceIsQuotedPerSegmentNotReSplit() {
        XCTAssertEqual(
            R2SQLIntrospectionSQL.describe(namespace: "a.b", table: "t"),
            "DESCRIBE \"a\".\"b\".\"t\""
        )
    }

    func testNamespaceWithEmbeddedQuoteIsEscaped() {
        XCTAssertEqual(
            R2SQLIntrospectionSQL.showTables(namespace: "we\"ird"),
            "SHOW TABLES IN \"we\"\"ird\""
        )
    }

    func testIntrospectionStatementsNeverContainOffset() {
        let statements = [
            R2SQLIntrospectionSQL.showNamespaces(),
            R2SQLIntrospectionSQL.showTables(namespace: "ns"),
            R2SQLIntrospectionSQL.describe(namespace: "ns", table: "t")
        ]
        for statement in statements {
            XCTAssertFalse(statement.uppercased().contains("OFFSET"))
        }
    }
}
