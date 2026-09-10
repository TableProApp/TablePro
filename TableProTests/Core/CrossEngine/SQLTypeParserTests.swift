//
//  SQLTypeParserTests.swift
//  TableProTests
//

import XCTest
@testable import TablePro

final class SQLTypeParserTests: XCTestCase {
    private func kind(_ spelling: String, _ family: SQLTypeFamily) -> CanonicalTypeKind {
        SQLTypeParser.parse(spelling, family: family).kind
    }

    // MARK: - The same word means two things

    /// The reason the parser is keyed by family rather than by word. Each of these is read
    /// correctly for one engine and wrongly for the other by any shared table.
    func testTheSameWordIsReadDifferentlyPerEngine() {
        XCTAssertEqual(kind("TINYINT(1)", .mysql), .boolean)
        XCTAssertEqual(kind("TINYINT", .mssql), .integer(bytes: 1))
        XCTAssertEqual(kind("DATE", .postgres), .date)
        XCTAssertEqual(kind("DATE", .oracle), .timestamp(precision: 0, hasTimeZone: false))
        XCTAssertEqual(kind("REAL", .postgres), .floatingPoint(bits: 32))
        XCTAssertEqual(kind("REAL", .sqlite), .floatingPoint(bits: 64))
    }

    /// SQL Server's `TINYINT` holds 0 to 255, so it is unsigned however it is spelled.
    func testSQLServerTinyIntIsUnsigned() {
        XCTAssertTrue(SQLTypeParser.parse("TINYINT", family: .mssql).isUnsigned)
        XCTAssertFalse(SQLTypeParser.parse("TINYINT", family: .mysql).isUnsigned)
    }

    // MARK: - Modifiers

    func testUnsignedIsReadAsAModifierRatherThanAsPartOfTheName() {
        let parsed = SQLTypeParser.parse("BIGINT UNSIGNED", family: .mysql)
        XCTAssertEqual(parsed.kind, .integer(bytes: 8))
        XCTAssertTrue(parsed.isUnsigned)
    }

    func testZerofillDoesNotHideTheTypeName() {
        XCTAssertEqual(kind("INT UNSIGNED ZEROFILL", .mysql), .integer(bytes: 4))
    }

    /// Without stripping these every ClickHouse column is one unknown type called `Nullable`.
    func testClickHouseWrappersAreStripped() {
        XCTAssertEqual(kind("Nullable(Int32)", .clickhouse), .integer(bytes: 4))
        XCTAssertEqual(kind("LowCardinality(Nullable(String))", .clickhouse), .text(length: nil, isFixed: false))
    }

    // MARK: - Parameters

    func testLengthAndPrecisionAreKept() {
        XCTAssertEqual(kind("VARCHAR(255)", .mysql), .text(length: 255, isFixed: false))
        XCTAssertEqual(kind("CHAR(2)", .postgres), .text(length: 2, isFixed: true))
        XCTAssertEqual(kind("NUMERIC(19,4)", .postgres), .decimal(precision: 19, scale: 4))
        XCTAssertEqual(kind("DECIMAL(10)", .mysql), .decimal(precision: 10, scale: nil))
    }

    /// The parenthesised part sits in the middle of these, so a parser that stops at the first
    /// bracket reads `timestamp(3) with time zone` as an ordinary `timestamp`.
    func testASuffixAfterTheParametersIsPartOfTheName() {
        XCTAssertEqual(kind("timestamp(3) with time zone", .postgres), .timestamp(precision: 3, hasTimeZone: true))
        XCTAssertEqual(kind("time(6) without time zone", .postgres), .time(precision: 6, hasTimeZone: false))
    }

    func testEnumLabelsAreRead() {
        XCTAssertEqual(kind("enum('small','large')", .mysql), .enumeration(values: ["small", "large"]))
        XCTAssertEqual(
            kind("Enum8('a' = 1, 'b' = 2)", .clickhouse), .enumeration(values: ["a", "b"])
        )
    }

    func testAnEmptyParameterListIsNotALength() {
        XCTAssertEqual(kind("VARCHAR", .mysql), .text(length: nil, isFixed: false))
        XCTAssertEqual(kind("NVARCHAR(MAX)", .mssql), .text(length: nil, isFixed: false))
    }

    // MARK: - Arrays

    func testArraysAreReadOnBothSpellings() {
        XCTAssertEqual(kind("integer[]", .postgres), .array(element: .integer(bytes: 4)))
        XCTAssertEqual(kind("Array(String)", .clickhouse), .array(element: .text(length: nil, isFixed: false)))
    }

    // MARK: - Oracle numbers

    /// Oracle has one numeric type, so a whole-number column is `NUMBER(p, 0)` and only its
    /// precision says how wide an integer the target needs.
    /// The width is the narrowest integer that holds every value of that many digits, so the
    /// boundaries are where the digit count outgrows the type: 10 digits do not fit in four bytes
    /// and 19 do not fit in eight.
    func testOracleWholeNumbersBecomeIntegers() {
        XCTAssertEqual(kind("NUMBER(2,0)", .oracle), .integer(bytes: 1))
        XCTAssertEqual(kind("NUMBER(4,0)", .oracle), .integer(bytes: 2))
        XCTAssertEqual(kind("NUMBER(9,0)", .oracle), .integer(bytes: 4))
        XCTAssertEqual(kind("NUMBER(10,0)", .oracle), .integer(bytes: 8))
        XCTAssertEqual(kind("NUMBER(18,0)", .oracle), .integer(bytes: 8))
        XCTAssertEqual(kind("NUMBER(38,0)", .oracle), .integer(bytes: 16))
        XCTAssertEqual(kind("NUMBER(10,2)", .oracle), .decimal(precision: 10, scale: 2))
        XCTAssertEqual(kind("NUMBER", .oracle), .decimal(precision: nil, scale: nil))
    }

    // MARK: - Unknowns

    /// An unknown word carries its own spelling so the renderer can name it, rather than being
    /// guessed into a shape it does not have.
    func testAnUnknownTypeKeepsItsSpelling() {
        let parsed = SQLTypeParser.parse("tsvector", family: .postgres)
        XCTAssertEqual(parsed.kind, .unsupported)
        XCTAssertEqual(parsed.sourceSpelling, "tsvector")
    }

    /// SQLite stores whatever spelling the `CREATE TABLE` used, so a file written by another tool
    /// is full of other engines' words and none of them may fall through to unsupported.
    func testSQLiteFallsBackToTheAnsiReading() {
        XCTAssertEqual(kind("VARCHAR(80)", .sqlite), .text(length: 80, isFixed: false))
        XCTAssertEqual(kind("BOOLEAN", .sqlite), .boolean)
        XCTAssertEqual(kind("DATETIME", .sqlite), .timestamp(precision: nil, hasTimeZone: false))
    }
}
