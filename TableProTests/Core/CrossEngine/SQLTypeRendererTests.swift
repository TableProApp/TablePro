//
//  SQLTypeRendererTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SQLTypeRendererTests {
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

    @Test
    func mySQLToPostgres() {
        #expect(spelling("TINYINT(1)", from: .mysql, to: .postgres) == "BOOLEAN")
        #expect(spelling("INT", from: .mysql, to: .postgres) == "INTEGER")
        #expect(spelling("MEDIUMINT", from: .mysql, to: .postgres) == "INTEGER")
        #expect(spelling("VARCHAR(255)", from: .mysql, to: .postgres) == "VARCHAR(255)")
        #expect(spelling("LONGTEXT", from: .mysql, to: .postgres) == "TEXT")
        #expect(spelling("DATETIME(6)", from: .mysql, to: .postgres) == "TIMESTAMP(6)")
        #expect(spelling("LONGBLOB", from: .mysql, to: .postgres) == "BYTEA")
        #expect(spelling("JSON", from: .mysql, to: .postgres) == "JSONB")
        #expect(spelling("DOUBLE", from: .mysql, to: .postgres) == "DOUBLE PRECISION")
    }

    @Test
    func jSONForAPostgresTargetFollowsTheServerVersion() {
        let json = SQLTypeParser.parse("JSON", family: .mysql)
        #expect(SQLTypeRenderer.render(json, family: .postgres).spelling == "JSONB")
        #expect(SQLTypeRenderer.render(json, family: .postgres, jsonColumnType: .jsonb).spelling == "JSONB")
        #expect(SQLTypeRenderer.render(json, family: .postgres, jsonColumnType: .json).spelling == "JSON")

        let preJSON = SQLTypeRenderer.render(json, family: .postgres, jsonColumnType: .text)
        #expect(preJSON.spelling == "TEXT")
        #expect(preJSON.fidelity == .approximated)
        #expect(preJSON.reason != nil)
    }

    @Test
    func aJSONArrayForAPostgresTargetFollowsTheServerVersion() {
        let array = CanonicalColumnType(kind: .array(element: .json), isUnsigned: false, sourceSpelling: "jsonb[]")
        #expect(SQLTypeRenderer.render(array, family: .postgres, jsonColumnType: .json).spelling == "JSON[]")
        #expect(SQLTypeRenderer.render(array, family: .postgres).spelling == "JSONB[]")
    }

    /// Redshift reports 8.0.2 and CockroachDB reports 13.0.0. Reading either as a PostgreSQL
    /// version turned a `JSONB` column into `TEXT` on a target that holds `JSONB` perfectly well.
    @Test
    func onlyPostgreSQLItselfReadsTheReportedVersion() {
        #expect(PostgreSQLServerVersion.jsonColumnType(for: .postgresql, serverVersion: "9.1.24") == .text)
        #expect(PostgreSQLServerVersion.jsonColumnType(for: .redshift, serverVersion: "8.0.2") == .jsonb)
        #expect(PostgreSQLServerVersion.jsonColumnType(for: .cockroachdb, serverVersion: "13.0.0") == .jsonb)
    }

    @Test
    func postgresToMySQL() {
        #expect(spelling("boolean", from: .postgres, to: .mysql) == "TINYINT(1)")
        #expect(spelling("int4", from: .postgres, to: .mysql) == "INT")
        #expect(spelling("text", from: .postgres, to: .mysql) == "LONGTEXT")
        #expect(spelling("bytea", from: .postgres, to: .mysql) == "LONGBLOB")
        #expect(spelling("uuid", from: .postgres, to: .mysql) == "CHAR(36)")
        #expect(spelling("jsonb", from: .postgres, to: .mysql) == "JSON")
        #expect(spelling("numeric(19,4)", from: .postgres, to: .mysql) == "DECIMAL(19, 4)")
    }

    /// `text` on PostgreSQL holds a gigabyte and MySQL's `TEXT` holds 64 KB, so the unbounded case
    /// has to reach `LONGTEXT` or a long value is truncated with no error outside strict mode.
    @Test
    func unboundedTextReachesTheWidestMySQLType() {
        #expect(spelling("text", from: .postgres, to: .mysql) == "LONGTEXT")
        #expect(spelling("CLOB", from: .oracle, to: .mysql) == "LONGTEXT")
        #expect(spelling("NVARCHAR(MAX)", from: .mssql, to: .mysql) == "LONGTEXT")
    }

    // MARK: - Unsigned

    /// PostgreSQL has no unsigned integers. Kept at the same width, half of a `BIGINT UNSIGNED`'s
    /// range fails on whichever row first exceeds it, minutes into a copy.
    @Test
    func unsignedIntegersWidenRatherThanOverflow() {
        #expect(spelling("INT UNSIGNED", from: .mysql, to: .postgres) == "BIGINT")
        #expect(spelling("SMALLINT UNSIGNED", from: .mysql, to: .postgres) == "INTEGER")
        #expect(spelling("BIGINT UNSIGNED", from: .mysql, to: .postgres) == "NUMERIC(20, 0)")
        #expect(spelling("BIGINT UNSIGNED", from: .mysql, to: .mssql) == "DECIMAL(20, 0)")
    }

    /// `UNSIGNED` is a column attribute on the MySQL side, and the driver writes it from that
    /// attribute. Spelling it into the type as well produced `INT UNSIGNED UNSIGNED`.
    @Test
    func theMySQLRendererNeverSpellsUnsigned() {
        let type = CanonicalColumnType(kind: .integer(bytes: 4), isUnsigned: true, sourceSpelling: "int")
        #expect(SQLTypeRenderer.render(type, family: .mysql).spelling == "INT")
    }

    /// A signed byte does not fit in SQL Server's `TINYINT`, which holds 0 to 255.
    @Test
    func sQLServerWidensASignedByte() {
        #expect(spelling("TINYINT", from: .mysql, to: .mssql) == "SMALLINT")
        let unsigned = CanonicalColumnType(kind: .integer(bytes: 1), isUnsigned: true, sourceSpelling: "tinyint")
        #expect(SQLTypeRenderer.render(unsigned, family: .mssql).spelling == "TINYINT")
    }

    // MARK: - Fidelity

    @Test
    func anExactMappingReportsNothing() {
        let result = rendered("INT", from: .mysql, to: .postgres)
        #expect(result.fidelity == .exact)
        #expect(result.reason == nil)
    }

    @Test
    func aLossyMappingCarriesItsReason() {
        let result = rendered("timestamptz", from: .postgres, to: .mysql)
        #expect(result.fidelity == .approximated)
        #expect(result.reason != nil)
        #expect(result.spelling == "DATETIME(6)")
    }

    @Test
    func aWideningCarriesItsReasonAndKeepsEveryValue() {
        let result = rendered("uuid", from: .postgres, to: .mysql)
        #expect(result.fidelity == .widened)
        #expect(result.reason != nil)
    }

    /// Nothing is ever dropped. A type no family can express becomes the target's widest text and
    /// says so, because a copy that writes the value as text is better than one missing a column.
    @Test
    func anUnknownTypeBecomesTextRatherThanDisappearing() {
        for family in SQLTypeFamily.allCases where family != .postgres {
            let result = rendered("tsvector", from: .postgres, to: family)
            #expect(!result.spelling.isEmpty, "\(family) produced no spelling")
            #expect(result.fidelity == .approximated, "\(family)")
            #expect(result.reason != nil, "\(family)")
        }
    }

    /// Every family answers every kind, so no copy can be refused for a type the source happened
    /// to use.
    @Test
    func everyFamilyAnswersEveryKind() {
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
                #expect(!spelling.isEmpty, "\(family) had no spelling for \(kind)")
            }
        }
    }

    // MARK: - Enums

    @Test
    func aMySQLTargetKeepsAnEnum() {
        #expect(SQLTypeRenderer.render(
                SQLTypeParser.parse("enum('a','b')", family: .mysql), family: .mysql
            ).spelling == "ENUM('a', 'b')")
    }

    /// A label with a quote in it has to survive being written back out.
    @Test
    func anEnumLabelIsEscaped() {
        let type = CanonicalColumnType(kind: .enumeration(values: ["it's"]), sourceSpelling: "enum")
        #expect(SQLTypeRenderer.render(type, family: .mysql).spelling == "ENUM('it''s')")
    }

    /// PostgreSQL enums are a separate `CREATE TYPE` with a dependency of its own, so the column
    /// becomes text wide enough for the longest label and the review says so.
    @Test
    func aPostgresTargetSizesTextToTheLongestLabel() {
        let type = CanonicalColumnType(kind: .enumeration(values: ["a", "medium"]), sourceSpelling: "enum")
        #expect(SQLTypeRenderer.render(type, family: .postgres).spelling == "VARCHAR(6)")
    }

    // MARK: - Arrays

    @Test
    func aPostgresTargetKeepsAnArray() {
        #expect(spelling("integer[]", from: .postgres, to: .postgres) == "INTEGER[]")
        #expect(spelling("Array(Int32)", from: .clickhouse, to: .postgres) == "INTEGER[]")
    }

    @Test
    func anArrayBecomesJsonOnMySQL() {
        #expect(spelling("integer[]", from: .postgres, to: .mysql) == "JSON")
    }
}
