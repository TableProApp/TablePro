//
//  SQLTypeParserModifierTests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

final class SQLTypeParserModifierTests: XCTestCase {
    private func kind(_ spelling: String, _ family: SQLTypeFamily) -> CanonicalTypeKind {
        SQLTypeParser.parse(spelling, family: family).kind
    }

    private func parsed(_ dataType: String, catalog: String?) -> CanonicalColumnType {
        SQLTypeParser.parse(dataType, catalogSpelling: catalog, family: .postgres)
    }

    // MARK: - Catalog spelling

    /// `information_schema` reports each of these without its modifier, and `format_type` with it.
    func testTheCatalogSpellingCarriesTheModifier() {
        XCTAssertEqual(
            parsed("CHARACTER VARYING", catalog: "character varying(50)").kind, .text(length: 50, isFixed: false)
        )
        XCTAssertEqual(parsed("NUMERIC", catalog: "numeric(10,2)").kind, .decimal(precision: 10, scale: 2))
        XCTAssertEqual(parsed("CHARACTER", catalog: "character(10)").kind, .text(length: 10, isFixed: true))
        XCTAssertEqual(parsed("BIT", catalog: "bit(8)").kind, .bitString(length: 8))
        XCTAssertEqual(
            parsed("TIMESTAMP WITH TIME ZONE", catalog: "timestamp(3) with time zone").kind,
            .timestamp(precision: 3, hasTimeZone: true)
        )
        XCTAssertEqual(parsed("CHARACTER VARYING", catalog: "character varying(50)").sourceSpelling, "character varying(50)")
    }

    /// A type outside `pg_catalog` is named with its schema, which no family reads, while the display
    /// spelling still classifies it.
    func testAQualifiedCatalogSpellingGivesWayToTheDisplaySpelling() {
        let shape = parsed("geometry", catalog: "public.geometry(Point,4326)")
        XCTAssertEqual(shape.kind, .spatial)
        XCTAssertEqual(shape.sourceSpelling, "geometry")
        XCTAssertEqual(parsed("citext", catalog: "public.citext").kind, .text(length: nil, isFixed: false))
        XCTAssertEqual(parsed("NUMERIC", catalog: "public.price").kind, .decimal(precision: nil, scale: nil))
        XCTAssertEqual(
            parsed("geometry[]", catalog: "public.geometry(Point,4326)[]").kind, .array(element: .spatial)
        )

        let mood = parsed("ENUM", catalog: "public.mood")
        XCTAssertEqual(mood.kind, .unsupported)
        XCTAssertEqual(mood.sourceSpelling, "ENUM")
    }

    func testNoCatalogSpellingReadsTheDisplaySpelling() {
        XCTAssertEqual(parsed("CHARACTER VARYING", catalog: nil).kind, .text(length: nil, isFixed: false))
        XCTAssertEqual(parsed("CHARACTER VARYING", catalog: "").kind, .text(length: nil, isFixed: false))
    }

    func testAnArrayCatalogSpellingKeepsItsElementsModifier() {
        XCTAssertEqual(
            parsed("varchar[]", catalog: "character varying(50)[]").kind,
            .array(element: .text(length: 50, isFixed: false))
        )
    }

    // MARK: - PostgreSQL's omitted modifiers

    func testAnIntervalWithFieldsIsAnInterval() {
        for spelling in [
            "interval hour to minute", "interval day to second(3)", "interval second(2)", "interval year",
            "interval(3)", "interval"
        ] {
            XCTAssertEqual(kind(spelling, .postgres), .interval, spelling)
        }
    }

    /// `information_schema.columns.datetime_precision` is 6 for each of these.
    func testATimeOrTimestampWithoutPrecisionKeepsMicroseconds() {
        XCTAssertEqual(kind("timestamp without time zone", .postgres), .timestamp(precision: 6, hasTimeZone: false))
        XCTAssertEqual(kind("timestamp with time zone", .postgres), .timestamp(precision: 6, hasTimeZone: true))
        XCTAssertEqual(kind("TIMESTAMPTZ", .postgres), .timestamp(precision: 6, hasTimeZone: true))
        XCTAssertEqual(kind("time without time zone", .postgres), .time(precision: 6, hasTimeZone: false))
        XCTAssertEqual(kind("time with time zone", .postgres), .time(precision: 6, hasTimeZone: true))
        XCTAssertEqual(kind("timestamp(0) with time zone", .postgres), .timestamp(precision: 0, hasTimeZone: true))
    }

    func testOnlyPostgreSQLReadsATimestampWithoutPrecisionAsMicroseconds() {
        XCTAssertEqual(kind("DATETIME", .mysql), .timestamp(precision: nil, hasTimeZone: false))
        XCTAssertEqual(kind("TIMESTAMP", .generic), .timestamp(precision: nil, hasTimeZone: false))
    }

    /// PostgreSQL's `numeric` with no modifier has no precision limit. Every other family's bare
    /// decimal keeps the 38 digits it has always been read with, because Oracle reports an `INTEGER`
    /// that way too.
    func testOnlyPostgreSQLReadsABareDecimalAsUnconstrained() {
        XCTAssertEqual(kind("numeric", .postgres), .decimal(precision: nil, scale: nil))
        XCTAssertEqual(kind("numeric(10,2)", .postgres), .decimal(precision: 10, scale: 2))
        for family in SQLTypeFamily.allCases where family != .postgres {
            let spelling = family == .oracle ? "NUMBER" : "DECIMAL"
            XCTAssertEqual(kind(spelling, family), .decimal(precision: 38, scale: nil), "\(family)")
        }
    }

    // MARK: - Oracle length semantics

    func testAnOracleLengthNamingItsUnitIsStillALength() {
        XCTAssertEqual(kind("VARCHAR2(50 CHAR)", .oracle), .text(length: 50, isFixed: false))
        XCTAssertEqual(kind("VARCHAR2(50 BYTE)", .oracle), .text(length: 50, isFixed: false))
        XCTAssertEqual(kind("CHAR(10 CHAR)", .oracle), .text(length: 10, isFixed: true))
        XCTAssertEqual(kind("VARCHAR2(50)", .oracle), .text(length: 50, isFixed: false))
    }
}
