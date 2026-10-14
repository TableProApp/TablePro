//
//  SQLTypeParserModifierTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SQLTypeParserModifierTests {
    private func kind(_ spelling: String, _ family: SQLTypeFamily) -> CanonicalTypeKind {
        SQLTypeParser.parse(spelling, family: family).kind
    }

    private func parsed(_ dataType: String, catalog: String?) -> CanonicalColumnType {
        SQLTypeParser.parse(dataType, catalogSpelling: catalog, family: .postgres)
    }

    // MARK: - Catalog spelling

    /// `information_schema` reports each of these without its modifier, and `format_type` with it.
    @Test
    func theCatalogSpellingCarriesTheModifier() {
        #expect(parsed("CHARACTER VARYING", catalog: "character varying(50)").kind == .text(length: 50, isFixed: false))
        #expect(parsed("NUMERIC", catalog: "numeric(10,2)").kind == .decimal(precision: 10, scale: 2))
        #expect(parsed("CHARACTER", catalog: "character(10)").kind == .text(length: 10, isFixed: true))
        #expect(parsed("BIT", catalog: "bit(8)").kind == .bitString(length: 8))
        #expect(parsed("TIMESTAMP WITH TIME ZONE", catalog: "timestamp(3) with time zone").kind == .timestamp(precision: 3, hasTimeZone: true))
        #expect(parsed("CHARACTER VARYING", catalog: "character varying(50)").sourceSpelling == "character varying(50)")
    }

    /// A type outside `pg_catalog` is named with its schema, which no family reads, while the display
    /// spelling still classifies it.
    @Test
    func aQualifiedCatalogSpellingGivesWayToTheDisplaySpelling() {
        let shape = parsed("geometry", catalog: "public.geometry(Point,4326)")
        #expect(shape.kind == .spatial)
        #expect(shape.sourceSpelling == "geometry")
        #expect(parsed("citext", catalog: "public.citext").kind == .text(length: nil, isFixed: false))
        #expect(parsed("NUMERIC", catalog: "public.price").kind == .decimal(precision: nil, scale: nil))
        #expect(parsed("geometry[]", catalog: "public.geometry(Point,4326)[]").kind == .array(element: .spatial))

        let mood = parsed("ENUM", catalog: "public.mood")
        #expect(mood.kind == .unsupported)
        #expect(mood.sourceSpelling == "ENUM")
    }

    @Test
    func noCatalogSpellingReadsTheDisplaySpelling() {
        #expect(parsed("CHARACTER VARYING", catalog: nil).kind == .text(length: nil, isFixed: false))
        #expect(parsed("CHARACTER VARYING", catalog: "").kind == .text(length: nil, isFixed: false))
    }

    @Test
    func anArrayCatalogSpellingKeepsItsElementsModifier() {
        #expect(parsed("varchar[]", catalog: "character varying(50)[]").kind == .array(element: .text(length: 50, isFixed: false)))
    }

    // MARK: - PostgreSQL's omitted modifiers

    @Test
    func anIntervalWithFieldsIsAnInterval() {
        for spelling in [
            "interval hour to minute", "interval day to second(3)", "interval second(2)", "interval year",
            "interval(3)", "interval"
        ] {
            #expect(kind(spelling, .postgres) == .interval, Comment(rawValue: spelling))
        }
    }

    /// `information_schema.columns.datetime_precision` is 6 for each of these.
    @Test
    func aTimeOrTimestampWithoutPrecisionKeepsMicroseconds() {
        #expect(kind("timestamp without time zone", .postgres) == .timestamp(precision: 6, hasTimeZone: false))
        #expect(kind("timestamp with time zone", .postgres) == .timestamp(precision: 6, hasTimeZone: true))
        #expect(kind("TIMESTAMPTZ", .postgres) == .timestamp(precision: 6, hasTimeZone: true))
        #expect(kind("time without time zone", .postgres) == .time(precision: 6, hasTimeZone: false))
        #expect(kind("time with time zone", .postgres) == .time(precision: 6, hasTimeZone: true))
        #expect(kind("timestamp(0) with time zone", .postgres) == .timestamp(precision: 0, hasTimeZone: true))
    }

    @Test
    func onlyPostgreSQLReadsATimestampWithoutPrecisionAsMicroseconds() {
        #expect(kind("DATETIME", .mysql) == .timestamp(precision: nil, hasTimeZone: false))
        #expect(kind("TIMESTAMP", .generic) == .timestamp(precision: nil, hasTimeZone: false))
    }

    /// PostgreSQL's `numeric` with no modifier has no precision limit. Every other family's bare
    /// decimal keeps the 38 digits it has always been read with, which is what a bare Oracle `NUMBER`
    /// holds.
    @Test
    func onlyPostgreSQLReadsABareDecimalAsUnconstrained() {
        #expect(kind("numeric", .postgres) == .decimal(precision: nil, scale: nil))
        #expect(kind("numeric(10,2)", .postgres) == .decimal(precision: 10, scale: 2))
        for family in SQLTypeFamily.allCases where family != .postgres {
            let spelling = family == .oracle ? "NUMBER" : "DECIMAL"
            #expect(kind(spelling, family) == .decimal(precision: 38, scale: nil), "\(family)")
        }
    }

    // MARK: - Oracle length semantics

    @Test
    func anOracleLengthNamingItsUnitIsStillALength() {
        #expect(kind("VARCHAR2(50 CHAR)", .oracle) == .text(length: 50, isFixed: false))
        #expect(kind("VARCHAR2(50 BYTE)", .oracle) == .text(length: 50, isFixed: false))
        #expect(kind("CHAR(10 CHAR)", .oracle) == .text(length: 10, isFixed: true))
        #expect(kind("VARCHAR2(50)", .oracle) == .text(length: 50, isFixed: false))
    }
}
