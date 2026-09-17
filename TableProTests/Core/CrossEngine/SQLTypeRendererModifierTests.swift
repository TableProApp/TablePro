//
//  SQLTypeRendererModifierTests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

final class SQLTypeRendererModifierTests: XCTestCase {
    private func rendered(
        _ spelling: String,
        from source: SQLTypeFamily,
        to target: SQLTypeFamily
    ) -> RenderedColumnType {
        SQLTypeRenderer.render(SQLTypeParser.parse(spelling, family: source), family: target)
    }

    private func spelling(_ value: String, from source: SQLTypeFamily, to target: SQLTypeFamily) -> String {
        rendered(value, from: source, to: target).spelling
    }

    private let unconstrained = CanonicalColumnType(
        kind: .decimal(precision: nil, scale: nil), sourceSpelling: "numeric"
    )

    // MARK: - PostgreSQL catalog spellings

    func testPostgresModifiersReachMySQL() {
        let amount = rendered("numeric(10,2)", from: .postgres, to: .mysql)
        XCTAssertEqual(amount.spelling, "DECIMAL(10, 2)")
        XCTAssertEqual(amount.fidelity, .exact)
        XCTAssertEqual(spelling("character varying(50)", from: .postgres, to: .mysql), "VARCHAR(50)")
        XCTAssertEqual(spelling("character(10)", from: .postgres, to: .mysql), "CHAR(10)")
        XCTAssertEqual(spelling("time(6) without time zone", from: .postgres, to: .mysql), "TIME(6)")
        XCTAssertEqual(spelling("bit(8)", from: .postgres, to: .mysql), "BIT(8)")

        let made = rendered("timestamp(3) with time zone", from: .postgres, to: .mysql)
        XCTAssertEqual(made.spelling, "DATETIME(3)")
        XCTAssertEqual(made.fidelity, .approximated)
    }

    /// A bare PostgreSQL timestamp stores microseconds, and a MySQL `DATETIME` without a precision
    /// stores whole seconds.
    func testAPostgresTimestampWithoutPrecisionKeepsMicrosecondsEverywhere() {
        XCTAssertEqual(spelling("timestamp without time zone", from: .postgres, to: .mysql), "DATETIME(6)")
        XCTAssertEqual(rendered("timestamp without time zone", from: .postgres, to: .mysql).fidelity, .exact)
        XCTAssertEqual(spelling("timestamp without time zone", from: .postgres, to: .mssql), "DATETIME2(6)")
        XCTAssertEqual(spelling("timestamp with time zone", from: .postgres, to: .clickhouse), "DateTime64(6)")
        XCTAssertEqual(spelling("time without time zone", from: .postgres, to: .mysql), "TIME(6)")
    }

    func testPostgresModifiersReachTheRegistryEngines() {
        XCTAssertEqual(spelling("character varying(50)", from: .postgres, to: .mssql), "NVARCHAR(50)")
        XCTAssertEqual(spelling("character varying(50)", from: .postgres, to: .oracle), "VARCHAR2(50 CHAR)")
        XCTAssertEqual(spelling("character varying(50)", from: .postgres, to: .duckdb), "VARCHAR(50)")
        XCTAssertEqual(
            spelling("timestamp(3) with time zone", from: .postgres, to: .mssql), "DATETIMEOFFSET(3)"
        )
        XCTAssertEqual(
            spelling("timestamp(3) with time zone", from: .postgres, to: .oracle), "TIMESTAMP(3) WITH TIME ZONE"
        )
        XCTAssertEqual(spelling("timestamp(3) with time zone", from: .postgres, to: .clickhouse), "DateTime64(3)")
        XCTAssertEqual(spelling("numeric(10,2)", from: .postgres, to: .oracle), "NUMBER(10, 2)")
        XCTAssertEqual(spelling("numeric(10,2)", from: .postgres, to: .clickhouse), "Decimal(10, 2)")
    }

    // MARK: - Unconstrained decimals

    /// Each engine's widest precision, keeping 20 digits before the point and at most 30 after it.
    func testAnUnconstrainedDecimalTakesTheEnginesWidestPrecision() {
        let expected: [SQLTypeFamily: String] = [
            .mysql: "DECIMAL(65, 30)",
            .mssql: "DECIMAL(38, 18)",
            .duckdb: "DECIMAL(38, 18)",
            .generic: "DECIMAL(38, 18)",
            .clickhouse: "Decimal(76, 30)"
        ]
        for (family, spelling) in expected {
            let result = SQLTypeRenderer.render(unconstrained, family: family)
            XCTAssertEqual(result.spelling, spelling, "\(family)")
            XCTAssertEqual(result.fidelity, .approximated, "\(family)")
            XCTAssertNotNil(result.reason, "\(family)")
        }
    }

    func testAnUnconstrainedDecimalStaysUnconstrainedWhereTheEngineHasOne() {
        for family in [SQLTypeFamily.postgres, .sqlite] {
            let result = SQLTypeRenderer.render(unconstrained, family: family)
            XCTAssertEqual(result.spelling, "NUMERIC", "\(family)")
            XCTAssertEqual(result.fidelity, .exact, "\(family)")
        }
        let oracle = SQLTypeRenderer.render(unconstrained, family: .oracle)
        XCTAssertEqual(oracle.spelling, "NUMBER")
        XCTAssertEqual(oracle.fidelity, .approximated)
        XCTAssertNotNil(oracle.reason)
    }

    func testEveryFamilyAnswersAnUnconstrainedDecimal() {
        for family in SQLTypeFamily.allCases {
            XCTAssertFalse(SQLTypeRenderer.render(unconstrained, family: family).spelling.isEmpty, "\(family)")
        }
    }

    /// Oracle reports an `INTEGER` as a bare `number`. Read as unconstrained it would reach MySQL as
    /// `DECIMAL(65, 30)`, which refuses a 36-digit integer a `DECIMAL(38)` holds.
    func testABareOracleNumberKeepsItsExactRendering() {
        let toMySQL = rendered("NUMBER", from: .oracle, to: .mysql)
        XCTAssertEqual(toMySQL.spelling, "DECIMAL(38)")
        XCTAssertEqual(toMySQL.fidelity, .exact)
        XCTAssertEqual(spelling("NUMBER", from: .oracle, to: .mssql), "DECIMAL(38)")
        XCTAssertEqual(spelling("NUMBER", from: .oracle, to: .postgres), "NUMERIC(38)")
    }

    // MARK: - Oracle character semantics

    /// A byte length refuses multibyte text an engine counting characters accepted, so the length
    /// says `CHAR` and a column whose four-byte worst case passes Oracle's byte ceiling moves up.
    func testOracleTextCountsCharactersWithinItsByteCeiling() {
        let text = { (length: Int, isFixed: Bool) in
            SQLTypeRenderer.render(
                CanonicalColumnType(kind: .text(length: length, isFixed: isFixed), sourceSpelling: "text"),
                family: .oracle
            )
        }
        XCTAssertEqual(text(1_000, false).spelling, "VARCHAR2(1000 CHAR)")
        XCTAssertEqual(text(1_001, false).spelling, "CLOB")
        XCTAssertEqual(text(1_001, false).fidelity, .widened)
        XCTAssertEqual(text(500, true).spelling, "CHAR(500 CHAR)")
        XCTAssertEqual(text(501, true).spelling, "VARCHAR2(501 CHAR)")
        XCTAssertEqual(
            SQLTypeParser.parse(text(1_000, false).spelling, family: .oracle).kind,
            .text(length: 1_000, isFixed: false)
        )
    }
}
