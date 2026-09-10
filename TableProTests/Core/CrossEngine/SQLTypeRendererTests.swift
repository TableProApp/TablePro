//
//  SQLTypeRendererTests.swift
//  TableProTests
//

import XCTest
@testable import TablePro

final class SQLTypeRendererTests: XCTestCase {
    private func rendered(
        _ spelling: String,
        from source: SQLTypeFamily,
        to target: SQLTypeFamily
    ) -> RenderedColumnType {
        SQLTypeRenderer.render(SQLTypeParser.parse(spelling, family: source), family: target)
    }

    private func spelling(
        _ value: String,
        from source: SQLTypeFamily,
        to target: SQLTypeFamily
    ) -> String {
        rendered(value, from: source, to: target).spelling
    }

    // MARK: - The pairs users actually copy

    func testMySQLToPostgres() {
        XCTAssertEqual(spelling("TINYINT(1)", from: .mysql, to: .postgres), "BOOLEAN")
        XCTAssertEqual(spelling("INT", from: .mysql, to: .postgres), "INTEGER")
        XCTAssertEqual(spelling("MEDIUMINT", from: .mysql, to: .postgres), "INTEGER")
        XCTAssertEqual(spelling("VARCHAR(255)", from: .mysql, to: .postgres), "VARCHAR(255)")
        XCTAssertEqual(spelling("LONGTEXT", from: .mysql, to: .postgres), "TEXT")
        XCTAssertEqual(spelling("DATETIME(6)", from: .mysql, to: .postgres), "TIMESTAMP(6)")
        XCTAssertEqual(spelling("LONGBLOB", from: .mysql, to: .postgres), "BYTEA")
        XCTAssertEqual(spelling("JSON", from: .mysql, to: .postgres), "JSONB")
        XCTAssertEqual(spelling("DOUBLE", from: .mysql, to: .postgres), "DOUBLE PRECISION")
    }

    func testPostgresToMySQL() {
        XCTAssertEqual(spelling("boolean", from: .postgres, to: .mysql), "TINYINT(1)")
        XCTAssertEqual(spelling("int4", from: .postgres, to: .mysql), "INT")
        XCTAssertEqual(spelling("text", from: .postgres, to: .mysql), "LONGTEXT")
        XCTAssertEqual(spelling("bytea", from: .postgres, to: .mysql), "LONGBLOB")
        XCTAssertEqual(spelling("uuid", from: .postgres, to: .mysql), "CHAR(36)")
        XCTAssertEqual(spelling("jsonb", from: .postgres, to: .mysql), "JSON")
        XCTAssertEqual(spelling("numeric(19,4)", from: .postgres, to: .mysql), "DECIMAL(19, 4)")
    }

    /// `text` on PostgreSQL holds a gigabyte and MySQL's `TEXT` holds 64 KB, so the unbounded case
    /// has to reach `LONGTEXT` or a long value is truncated with no error outside strict mode.
    func testUnboundedTextReachesTheWidestMySQLType() {
        XCTAssertEqual(spelling("text", from: .postgres, to: .mysql), "LONGTEXT")
        XCTAssertEqual(spelling("CLOB", from: .oracle, to: .mysql), "LONGTEXT")
        XCTAssertEqual(spelling("NVARCHAR(MAX)", from: .mssql, to: .mysql), "LONGTEXT")
    }

    // MARK: - Unsigned

    /// PostgreSQL has no unsigned integers. Kept at the same width, half of a `BIGINT UNSIGNED`'s
    /// range fails on whichever row first exceeds it, minutes into a copy.
    func testUnsignedIntegersWidenRatherThanOverflow() {
        XCTAssertEqual(spelling("INT UNSIGNED", from: .mysql, to: .postgres), "BIGINT")
        XCTAssertEqual(spelling("SMALLINT UNSIGNED", from: .mysql, to: .postgres), "INTEGER")
        XCTAssertEqual(spelling("BIGINT UNSIGNED", from: .mysql, to: .postgres), "NUMERIC(20, 0)")
        XCTAssertEqual(spelling("BIGINT UNSIGNED", from: .mysql, to: .mssql), "DECIMAL(20, 0)")
    }

    /// `UNSIGNED` is a column attribute on the MySQL side, and the driver writes it from that
    /// attribute. Spelling it into the type as well produced `INT UNSIGNED UNSIGNED`.
    func testTheMySQLRendererNeverSpellsUnsigned() {
        let type = CanonicalColumnType(kind: .integer(bytes: 4), isUnsigned: true, sourceSpelling: "int")
        XCTAssertEqual(SQLTypeRenderer.render(type, family: .mysql).spelling, "INT")
    }

    /// A signed byte does not fit in SQL Server's `TINYINT`, which holds 0 to 255.
    func testSQLServerWidensASignedByte() {
        XCTAssertEqual(spelling("TINYINT", from: .mysql, to: .mssql), "SMALLINT")
        let unsigned = CanonicalColumnType(kind: .integer(bytes: 1), isUnsigned: true, sourceSpelling: "tinyint")
        XCTAssertEqual(SQLTypeRenderer.render(unsigned, family: .mssql).spelling, "TINYINT")
    }

    // MARK: - Fidelity

    func testAnExactMappingReportsNothing() {
        let result = rendered("INT", from: .mysql, to: .postgres)
        XCTAssertEqual(result.fidelity, .exact)
        XCTAssertNil(result.reason)
    }

    func testALossyMappingCarriesItsReason() {
        let result = rendered("timestamptz", from: .postgres, to: .mysql)
        XCTAssertEqual(result.fidelity, .approximated)
        XCTAssertNotNil(result.reason)
        XCTAssertEqual(result.spelling, "DATETIME")
    }

    func testAWideningCarriesItsReasonAndKeepsEveryValue() {
        let result = rendered("uuid", from: .postgres, to: .mysql)
        XCTAssertEqual(result.fidelity, .widened)
        XCTAssertNotNil(result.reason)
    }

    /// Nothing is ever dropped. A type no family can express becomes the target's widest text and
    /// says so, because a copy that writes the value as text is better than one missing a column.
    func testAnUnknownTypeBecomesTextRatherThanDisappearing() {
        for family in SQLTypeFamily.allCases where family != .postgres {
            let result = rendered("tsvector", from: .postgres, to: family)
            XCTAssertFalse(result.spelling.isEmpty, "\(family) produced no spelling")
            XCTAssertEqual(result.fidelity, .approximated, "\(family)")
            XCTAssertNotNil(result.reason, "\(family)")
        }
    }

    /// Every family answers every kind, so no copy can be refused for a type the source happened
    /// to use.
    func testEveryFamilyAnswersEveryKind() {
        let kinds: [CanonicalTypeKind] = [
            .boolean, .integer(bytes: 4), .decimal(precision: 10, scale: 2), .floatingPoint(bits: 64),
            .text(length: nil, isFixed: false), .binary(length: nil, isFixed: false), .date,
            .time(precision: nil, hasTimeZone: true), .timestamp(precision: 3, hasTimeZone: true),
            .interval, .uuid, .json, .xml, .enumeration(values: ["a"]), .bitString(length: 8),
            .money, .spatial, .array(element: .integer(bytes: 4)), .unsupported
        ]
        for family in SQLTypeFamily.allCases {
            for kind in kinds {
                let type = CanonicalColumnType(kind: kind, sourceSpelling: "source_type")
                let spelling = SQLTypeRenderer.render(type, family: family).spelling
                XCTAssertFalse(spelling.isEmpty, "\(family) had no spelling for \(kind)")
            }
        }
    }

    // MARK: - Enums

    func testAMySQLTargetKeepsAnEnum() {
        XCTAssertEqual(
            SQLTypeRenderer.render(
                SQLTypeParser.parse("enum('a','b')", family: .mysql), family: .mysql
            ).spelling,
            "ENUM('a', 'b')"
        )
    }

    /// A label with a quote in it has to survive being written back out.
    func testAnEnumLabelIsEscaped() {
        let type = CanonicalColumnType(kind: .enumeration(values: ["it's"]), sourceSpelling: "enum")
        XCTAssertEqual(SQLTypeRenderer.render(type, family: .mysql).spelling, "ENUM('it''s')")
    }

    /// PostgreSQL enums are a separate `CREATE TYPE` with a dependency of its own, so the column
    /// becomes text wide enough for the longest label and the review says so.
    func testAPostgresTargetSizesTextToTheLongestLabel() {
        let type = CanonicalColumnType(kind: .enumeration(values: ["a", "medium"]), sourceSpelling: "enum")
        XCTAssertEqual(SQLTypeRenderer.render(type, family: .postgres).spelling, "VARCHAR(6)")
    }

    // MARK: - Arrays

    func testAPostgresTargetKeepsAnArray() {
        XCTAssertEqual(spelling("integer[]", from: .postgres, to: .postgres), "INTEGER[]")
        XCTAssertEqual(spelling("Array(Int32)", from: .clickhouse, to: .postgres), "INTEGER[]")
    }

    func testAnArrayBecomesJsonOnMySQL() {
        XCTAssertEqual(spelling("integer[]", from: .postgres, to: .mysql), "JSON")
    }
}
