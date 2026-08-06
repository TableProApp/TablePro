import XCTest
@testable import TableProR2SQLCore

final class R2SQLQueryBuilderTests: XCTestCase {
    func testBrowseQueryNeverEmitsOffset() {
        let sql = R2SQLQueryBuilder.browseQuery(namespace: "analytics", table: "events", limit: 1_000)
        XCTAssertFalse(sql.uppercased().contains("OFFSET"))
        XCTAssertEqual(sql, "SELECT * FROM \"analytics\".\"events\" LIMIT 1000")
    }

    func testFilteredQueryNeverEmitsOffset() {
        let sql = R2SQLQueryBuilder.filteredQuery(
            namespace: "analytics",
            table: "events",
            filters: [R2SQLFilter(column: "status", op: "=", value: "ok")],
            matchAll: true,
            limit: 100
        )
        XCTAssertFalse(sql.uppercased().contains("OFFSET"))
        XCTAssertEqual(sql, "SELECT * FROM \"analytics\".\"events\" WHERE \"status\" = 'ok' LIMIT 100")
    }

    func testLimitIsClampedToEngineMaximum() {
        let sql = R2SQLQueryBuilder.browseQuery(namespace: "ns", table: "t", limit: 50_000)
        XCTAssertTrue(sql.hasSuffix("LIMIT 10000"))
    }

    func testLimitIsClampedToEngineMinimum() {
        let sql = R2SQLQueryBuilder.browseQuery(namespace: "ns", table: "t", limit: 0)
        XCTAssertTrue(sql.hasSuffix("LIMIT 1"))
    }

    func testDottedNamespaceIsQuotedPerSegment() {
        let sql = R2SQLQueryBuilder.browseQuery(namespace: "a.b", table: "t", limit: 10)
        XCTAssertEqual(sql, "SELECT * FROM \"a\".\"b\".\"t\" LIMIT 10")
    }

    func testEmptyNamespaceOmitsQualification() {
        let sql = R2SQLQueryBuilder.browseQuery(namespace: "", table: "t", limit: 10)
        XCTAssertEqual(sql, "SELECT * FROM \"t\" LIMIT 10")
    }

    func testExplicitColumnsAreQuoted() {
        let sql = R2SQLQueryBuilder.browseQuery(
            namespace: "ns",
            table: "t",
            columns: ["id", "user name"],
            limit: 10
        )
        XCTAssertEqual(sql, "SELECT \"id\", \"user name\" FROM \"ns\".\"t\" LIMIT 10")
    }

    func testOrderByRendersDirectionPerColumn() {
        let sql = R2SQLQueryBuilder.browseQuery(
            namespace: "ns",
            table: "t",
            sortColumns: [
                R2SQLSortColumn(name: "ts", ascending: false),
                R2SQLSortColumn(name: "id", ascending: true)
            ],
            limit: 10
        )
        XCTAssertEqual(sql, "SELECT * FROM \"ns\".\"t\" ORDER BY \"ts\" DESC, \"id\" ASC LIMIT 10")
    }

    func testIdentifierWithEmbeddedQuoteIsEscaped() {
        let sql = R2SQLQueryBuilder.browseQuery(namespace: "ns", table: "na\"me", limit: 10)
        XCTAssertEqual(sql, "SELECT * FROM \"ns\".\"na\"\"me\" LIMIT 10")
    }

    func testInjectionAttemptStaysInsideStringLiteral() {
        let sql = R2SQLQueryBuilder.filteredQuery(
            namespace: "ns",
            table: "t",
            filters: [R2SQLFilter(column: "name", op: "=", value: "'; DROP TABLE users; --")],
            matchAll: true,
            limit: 10
        )
        XCTAssertEqual(
            sql,
            "SELECT * FROM \"ns\".\"t\" WHERE \"name\" = '''; DROP TABLE users; --' LIMIT 10"
        )
    }

    func testNullBytesAreStrippedFromLiterals() {
        XCTAssertEqual(R2SQLLiteral.escapeStringLiteral("a\u{0}b"), "ab")
    }

    func testOrFiltersJoinWithOr() {
        let clause = R2SQLQueryBuilder.whereClause(
            filters: [
                R2SQLFilter(column: "a", op: "=", value: "1"),
                R2SQLFilter(column: "b", op: "=", value: "2")
            ],
            matchAll: false
        )
        XCTAssertEqual(clause, "\"a\" = 1 OR \"b\" = 2")
    }

    func testNullPredicatesRenderWithoutValue() {
        XCTAssertEqual(
            R2SQLQueryBuilder.whereClause(
                filters: [R2SQLFilter(column: "a", op: "IS NULL", value: "")],
                matchAll: true
            ),
            "\"a\" IS NULL"
        )
    }

    func testContainsBecomesLikeWithWildcards() {
        XCTAssertEqual(
            R2SQLQueryBuilder.whereClause(
                filters: [R2SQLFilter(column: "a", op: "contains", value: "abc")],
                matchAll: true
            ),
            "\"a\" LIKE '%abc%'"
        )
    }

    func testInListRendersEachItem() {
        XCTAssertEqual(
            R2SQLQueryBuilder.whereClause(
                filters: [R2SQLFilter(column: "a", op: "IN", value: "1, 2, x")],
                matchAll: true
            ),
            "\"a\" IN (1, 2, 'x')"
        )
    }

    func testUnknownOperatorIsDroppedRatherThanInterpolated() {
        XCTAssertNil(
            R2SQLQueryBuilder.whereClause(
                filters: [R2SQLFilter(column: "a", op: "; DROP TABLE t", value: "1")],
                matchAll: true
            )
        )
    }

    func testEmptyColumnFilterIsDropped() {
        XCTAssertNil(
            R2SQLQueryBuilder.whereClause(
                filters: [R2SQLFilter(column: "", op: "=", value: "1")],
                matchAll: true
            )
        )
    }

    func testBooleanLiteralsAreNotQuoted() {
        XCTAssertEqual(
            R2SQLQueryBuilder.whereClause(
                filters: [R2SQLFilter(column: "a", op: "=", value: "TRUE")],
                matchAll: true
            ),
            "\"a\" = true"
        )
    }

    func testCountQueryHasNoLimitAndNoOffset() {
        let sql = R2SQLQueryBuilder.countQuery(namespace: "ns", table: "t")
        XCTAssertEqual(sql, "SELECT COUNT(*) AS total FROM \"ns\".\"t\"")
        XCTAssertFalse(sql.uppercased().contains("OFFSET"))
        XCTAssertFalse(sql.uppercased().contains("LIMIT"))
    }

    func testCountQueryAppliesFilters() {
        let sql = R2SQLQueryBuilder.countQuery(
            namespace: "ns",
            table: "t",
            filters: [R2SQLFilter(column: "a", op: ">", value: "5")]
        )
        XCTAssertEqual(sql, "SELECT COUNT(*) AS total FROM \"ns\".\"t\" WHERE \"a\" > 5")
    }
}
