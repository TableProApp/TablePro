//
//  SQLTypeParserTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SQLTypeParserTests {
    private func kind(_ spelling: String, _ family: SQLTypeFamily) -> CanonicalTypeKind {
        SQLTypeParser.parse(spelling, family: family).kind
    }

    // MARK: - The same word means two things

    /// The reason the parser is keyed by family rather than by word. Each of these is read
    /// correctly for one engine and wrongly for the other by any shared table.
    @Test
    func theSameWordIsReadDifferentlyPerEngine() {
        #expect(kind("TINYINT(1)", .mysql) == .boolean)
        #expect(kind("TINYINT", .mssql) == .integer(bytes: 1))
        #expect(kind("DATE", .postgres) == .date)
        #expect(kind("DATE", .oracle) == .timestamp(precision: 0, hasTimeZone: false))
        #expect(kind("REAL", .postgres) == .floatingPoint(bits: 32))
        #expect(kind("REAL", .sqlite) == .floatingPoint(bits: 64))
    }

    /// SQL Server's `TINYINT` holds 0 to 255, so it is unsigned however it is spelled.
    @Test
    func sQLServerTinyIntIsUnsigned() {
        #expect(SQLTypeParser.parse("TINYINT", family: .mssql).isUnsigned)
        #expect(!(SQLTypeParser.parse("TINYINT", family: .mysql).isUnsigned))
    }

    // MARK: - Modifiers

    @Test
    func unsignedIsReadAsAModifierRatherThanAsPartOfTheName() {
        let parsed = SQLTypeParser.parse("BIGINT UNSIGNED", family: .mysql)
        #expect(parsed.kind == .integer(bytes: 8))
        #expect(parsed.isUnsigned)
    }

    @Test
    func zerofillDoesNotHideTheTypeName() {
        #expect(kind("INT UNSIGNED ZEROFILL", .mysql) == .integer(bytes: 4))
    }

    /// Without stripping these every ClickHouse column is one unknown type called `Nullable`.
    @Test
    func clickHouseWrappersAreStripped() {
        #expect(kind("Nullable(Int32)", .clickhouse) == .integer(bytes: 4))
        #expect(kind("LowCardinality(Nullable(String))", .clickhouse) == .text(length: nil, isFixed: false))
    }

    // MARK: - Parameters

    @Test
    func lengthAndPrecisionAreKept() {
        #expect(kind("VARCHAR(255)", .mysql) == .text(length: 255, isFixed: false))
        #expect(kind("CHAR(2)", .postgres) == .text(length: 2, isFixed: true))
        #expect(kind("NUMERIC(19,4)", .postgres) == .decimal(precision: 19, scale: 4))
        #expect(kind("DECIMAL(10)", .mysql) == .decimal(precision: 10, scale: nil))
    }

    /// The parenthesised part sits in the middle of these, so a parser that stops at the first
    /// bracket reads `timestamp(3) with time zone` as an ordinary `timestamp`.
    @Test
    func aSuffixAfterTheParametersIsPartOfTheName() {
        #expect(kind("timestamp(3) with time zone", .postgres) == .timestamp(precision: 3, hasTimeZone: true))
        #expect(kind("time(6) without time zone", .postgres) == .time(precision: 6, hasTimeZone: false))
    }

    @Test
    func enumLabelsAreRead() {
        #expect(kind("enum('small','large')", .mysql) == .enumeration(values: ["small", "large"]))
        #expect(kind("Enum8('a' = 1, 'b' = 2)", .clickhouse) == .enumeration(values: ["a", "b"]))
    }

    @Test
    func anEmptyParameterListIsNotALength() {
        #expect(kind("VARCHAR", .mysql) == .text(length: nil, isFixed: false))
        #expect(kind("NVARCHAR(MAX)", .mssql) == .text(length: nil, isFixed: false))
    }

    // MARK: - Arrays

    @Test
    func arraysAreReadOnBothSpellings() {
        #expect(kind("integer[]", .postgres) == .array(element: .integer(bytes: 4)))
        #expect(kind("Array(String)", .clickhouse) == .array(element: .text(length: nil, isFixed: false)))
    }

    // MARK: - Oracle numbers

    /// Oracle has one numeric type, so a whole-number column is `NUMBER(p, 0)` and only its
    /// precision says how wide an integer the target needs.
    /// The width is the narrowest integer that holds every value of that many digits, so the
    /// boundaries are where the digit count outgrows the type: 10 digits do not fit in four bytes
    /// and 19 do not fit in eight.
    @Test
    func oracleWholeNumbersBecomeIntegers() {
        #expect(kind("NUMBER(2,0)", .oracle) == .integer(bytes: 1))
        #expect(kind("NUMBER(4,0)", .oracle) == .integer(bytes: 2))
        #expect(kind("NUMBER(9,0)", .oracle) == .integer(bytes: 4))
        #expect(kind("NUMBER(10,0)", .oracle) == .integer(bytes: 8))
        #expect(kind("NUMBER(18,0)", .oracle) == .integer(bytes: 8))
        #expect(kind("NUMBER(38,0)", .oracle) == .integer(bytes: 16))
        #expect(kind("NUMBER(10,2)", .oracle) == .decimal(precision: 10, scale: 2))
        #expect(kind("NUMBER", .oracle) == .decimal(precision: 38, scale: nil))
    }

    /// The catalog writes a whole-number column as `NUMBER(p)` and an `INTEGER` as `NUMBER(*,0)`. Read as a
    /// list of numbers, `NUMBER(10)` was a decimal and the `*` dropped out, so the scale became the precision.
    @Test
    func oracleCatalogSpellingsOfANumber() {
        #expect(kind("NUMBER(10)", .oracle) == .integer(bytes: 8))
        #expect(kind("NUMBER(4)", .oracle) == .integer(bytes: 2))
        #expect(kind("number(9)", .oracle) == .integer(bytes: 4))
        #expect(kind("NUMBER(*,0)", .oracle) == .integer(bytes: 16))
        #expect(kind("NUMBER(*, 0)", .oracle) == .integer(bytes: 16))
        #expect(kind("NUMBER(*,2)", .oracle) == .decimal(precision: 38, scale: 2))
        #expect(kind("NUMBER(*)", .oracle) == .decimal(precision: 38, scale: nil))
        #expect(kind("NUMBER(10,-2)", .oracle) == .decimal(precision: 10, scale: -2))
        #expect(kind("FLOAT(126)", .oracle) == .floatingPoint(bits: 64))
    }

    /// Oracle's reading of a lone parameter is its own: everywhere else it stays a precision with no scale.
    @Test
    func otherFamiliesStillReadALoneParameterAsAPrecision() {
        #expect(kind("DECIMAL(10)", .mysql) == .decimal(precision: 10, scale: nil))
        #expect(kind("numeric(10)", .postgres) == .decimal(precision: 10, scale: nil))
        #expect(kind("DECIMAL(10)", .mssql) == .decimal(precision: 10, scale: nil))
        #expect(kind("NUMBER(10)", .generic) == .decimal(precision: 10, scale: nil))
    }

    @Test
    func oracleTemporalTypesKeepTheirZoneAndPrecision() {
        #expect(kind("TIMESTAMP(6) WITH TIME ZONE", .oracle) == .timestamp(precision: 6, hasTimeZone: true))
        #expect(kind("TIMESTAMP(9) WITH LOCAL TIME ZONE", .oracle) == .timestamp(precision: 9, hasTimeZone: true))
        #expect(kind("TIMESTAMP(6)", .oracle) == .timestamp(precision: 6, hasTimeZone: false))
        #expect(kind("TIMESTAMP(0)", .oracle) == .timestamp(precision: 0, hasTimeZone: false))
        #expect(kind("INTERVAL YEAR(4) TO MONTH", .oracle) == .interval)
        #expect(kind("INTERVAL DAY(3) TO SECOND(2)", .oracle) == .interval)
    }

    @Test
    func oracleNationalCharacterTypesCountCharacters() {
        #expect(kind("NVARCHAR2(100)", .oracle) == .text(length: 100, isFixed: false))
        #expect(kind("NCHAR(10)", .oracle) == .text(length: 10, isFixed: true))
    }

    @Test
    func oracle23aiTypes() {
        #expect(kind("BOOLEAN", .oracle) == .boolean)
        #expect(kind("JSON", .oracle) == .json)
        #expect(kind("VECTOR", .oracle) == .unsupported)
        #expect(kind("VECTOR(3, FLOAT32)", .oracle) == .unsupported)
    }

    /// A type from another schema is spelled with its owner for DDL, and classified by its bare name.
    @Test
    func anOwnerQualifiedOracleTypeIsReadByItsBareName() {
        #expect(kind("\"MDSYS\".\"SDO_GEOMETRY\"", .oracle) == .unsupported)
        #expect(kind("REF \"APP\".\"T_ADDR\"", .oracle) == .unsupported)
        #expect(SQLTypeParser.parse("SDO_GEOMETRY", catalogSpelling: "\"MDSYS\".\"SDO_GEOMETRY\"", family: .oracle).kind == .spatial)
    }

    // MARK: - Unknowns

    /// An unknown word carries its own spelling so the renderer can name it, rather than being
    /// guessed into a shape it does not have.
    @Test
    func anUnknownTypeKeepsItsSpelling() {
        let parsed = SQLTypeParser.parse("tsvector", family: .postgres)
        #expect(parsed.kind == .unsupported)
        #expect(parsed.sourceSpelling == "tsvector")
    }

    /// SQLite stores whatever spelling the `CREATE TABLE` used, so a file written by another tool
    /// is full of other engines' words and none of them may fall through to unsupported.
    @Test
    func sQLiteFallsBackToTheAnsiReading() {
        #expect(kind("VARCHAR(80)", .sqlite) == .text(length: 80, isFixed: false))
        #expect(kind("BOOLEAN", .sqlite) == .boolean)
        #expect(kind("DATETIME", .sqlite) == .timestamp(precision: nil, hasTimeZone: false))
    }
}
