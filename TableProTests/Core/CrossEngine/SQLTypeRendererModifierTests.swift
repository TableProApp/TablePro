//
//  SQLTypeRendererModifierTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SQLTypeRendererModifierTests {
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

    @Test
    func postgresModifiersReachMySQL() {
        let amount = rendered("numeric(10,2)", from: .postgres, to: .mysql)
        #expect(amount.spelling == "DECIMAL(10, 2)")
        #expect(amount.fidelity == .exact)
        #expect(spelling("character varying(50)", from: .postgres, to: .mysql) == "VARCHAR(50)")
        #expect(spelling("character(10)", from: .postgres, to: .mysql) == "CHAR(10)")
        #expect(spelling("time(6) without time zone", from: .postgres, to: .mysql) == "TIME(6)")
        #expect(spelling("bit(8)", from: .postgres, to: .mysql) == "BIT(8)")

        let made = rendered("timestamp(3) with time zone", from: .postgres, to: .mysql)
        #expect(made.spelling == "DATETIME(3)")
        #expect(made.fidelity == .approximated)
    }

    /// A bare PostgreSQL timestamp stores microseconds, and a MySQL `DATETIME` without a precision
    /// stores whole seconds.
    @Test
    func aPostgresTimestampWithoutPrecisionKeepsMicrosecondsEverywhere() {
        #expect(spelling("timestamp without time zone", from: .postgres, to: .mysql) == "DATETIME(6)")
        #expect(rendered("timestamp without time zone", from: .postgres, to: .mysql).fidelity == .exact)
        #expect(spelling("timestamp without time zone", from: .postgres, to: .mssql) == "DATETIME2(6)")
        #expect(spelling("timestamp with time zone", from: .postgres, to: .clickhouse) == "DateTime64(6)")
        #expect(spelling("time without time zone", from: .postgres, to: .mysql) == "TIME(6)")
    }

    @Test
    func postgresModifiersReachTheRegistryEngines() {
        #expect(spelling("character varying(50)", from: .postgres, to: .mssql) == "NVARCHAR(50)")
        #expect(spelling("character varying(50)", from: .postgres, to: .oracle) == "VARCHAR2(50 CHAR)")
        #expect(spelling("character varying(50)", from: .postgres, to: .duckdb) == "VARCHAR(50)")
        #expect(spelling("timestamp(3) with time zone", from: .postgres, to: .mssql) == "DATETIMEOFFSET(3)")
        #expect(spelling("timestamp(3) with time zone", from: .postgres, to: .oracle) == "TIMESTAMP(3) WITH TIME ZONE")
        #expect(spelling("timestamp(3) with time zone", from: .postgres, to: .clickhouse) == "DateTime64(3)")
        #expect(spelling("numeric(10,2)", from: .postgres, to: .oracle) == "NUMBER(10, 2)")
        #expect(spelling("numeric(10,2)", from: .postgres, to: .clickhouse) == "Decimal(10, 2)")
    }

    // MARK: - Unconstrained decimals

    /// Each engine's widest precision, keeping 20 digits before the point and at most 30 after it.
    @Test
    func anUnconstrainedDecimalTakesTheEnginesWidestPrecision() {
        let expected: [SQLTypeFamily: String] = [
            .mysql: "DECIMAL(65, 30)",
            .mssql: "DECIMAL(38, 18)",
            .duckdb: "DECIMAL(38, 18)",
            .generic: "DECIMAL(38, 18)",
            .clickhouse: "Decimal(76, 30)"
        ]
        for (family, spelling) in expected {
            let result = SQLTypeRenderer.render(unconstrained, family: family)
            #expect(result.spelling == spelling, "\(family)")
            #expect(result.fidelity == .approximated, "\(family)")
            #expect(result.reason != nil, "\(family)")
        }
    }

    @Test
    func anUnconstrainedDecimalStaysUnconstrainedWhereTheEngineHasOne() {
        for family in [SQLTypeFamily.postgres, .sqlite] {
            let result = SQLTypeRenderer.render(unconstrained, family: family)
            #expect(result.spelling == "NUMERIC", "\(family)")
            #expect(result.fidelity == .exact, "\(family)")
        }
        let oracle = SQLTypeRenderer.render(unconstrained, family: .oracle)
        #expect(oracle.spelling == "NUMBER")
        #expect(oracle.fidelity == .approximated)
        #expect(oracle.reason != nil)
    }

    @Test
    func everyFamilyAnswersAnUnconstrainedDecimal() {
        for family in SQLTypeFamily.allCases {
            #expect(!(SQLTypeRenderer.render(unconstrained, family: family).spelling.isEmpty), "\(family)")
        }
    }

    /// A bare Oracle `NUMBER` keeps 38 significant digits. Read as unconstrained it would reach MySQL as
    /// `DECIMAL(65, 30)`, which refuses a 36-digit integer a `DECIMAL(38)` holds.
    @Test
    func aBareOracleNumberKeepsItsExactRendering() {
        let toMySQL = rendered("NUMBER", from: .oracle, to: .mysql)
        #expect(toMySQL.spelling == "DECIMAL(38)")
        #expect(toMySQL.fidelity == .exact)
        #expect(spelling("NUMBER", from: .oracle, to: .mssql) == "DECIMAL(38)")
        #expect(spelling("NUMBER", from: .oracle, to: .postgres) == "NUMERIC(38)")
    }

    // MARK: - Scales

    /// PostgreSQL 17 stores `numeric(5,-2)` as whole hundreds below 10^7 and `numeric(3,5)` as
    /// fractions below 10^-2. MySQL 8.4 and MariaDB 12.3 refuse `DECIMAL(5, -2)` with ERROR 1064
    /// and `DECIMAL(3, 5)` with ERROR 1427, and create `DECIMAL(7, 0)` and `DECIMAL(5, 5)`.
    @Test
    func aScaleOutsideThePrecisionKeepsTheDigitsItsValuesHave() {
        let rounded = rendered("numeric(5,-2)", from: .postgres, to: .mysql)
        #expect(rounded.spelling == "DECIMAL(7, 0)")
        #expect(rounded.fidelity == .widened)
        #expect(rounded.reason != nil)

        let tiny = rendered("numeric(3,5)", from: .postgres, to: .mysql)
        #expect(tiny.spelling == "DECIMAL(5, 5)")
        #expect(tiny.fidelity == .widened)

        #expect(spelling("numeric(5,-2)", from: .postgres, to: .mssql) == "DECIMAL(7, 0)")
        #expect(spelling("numeric(3,5)", from: .postgres, to: .duckdb) == "DECIMAL(5, 5)")
        #expect(spelling("numeric(5,-2)", from: .postgres, to: .clickhouse) == "Decimal(7, 0)")
        #expect(spelling("NUMBER(5,-2)", from: .oracle, to: .mysql) == "DECIMAL(7, 0)")
    }

    /// Oracle's `NUMBER` takes a scale from -84 to 127 with the same meaning.
    @Test
    func oracleKeepsAScaleOutsideThePrecisionAsWritten() {
        let rounded = rendered("numeric(5,-2)", from: .postgres, to: .oracle)
        #expect(rounded.spelling == "NUMBER(5, -2)")
        #expect(rounded.fidelity == .exact)
        #expect(spelling("numeric(3,5)", from: .postgres, to: .oracle) == "NUMBER(3, 5)")
        #expect(spelling("numeric(10,-90)", from: .postgres, to: .oracle) == "NUMBER(38, 0)")
    }

    /// MySQL 8.4 refuses `DECIMAL(40, 35)` and `DECIMAL(65, 31)` with ERROR 1425, a scale over 30, and
    /// creates `DECIMAL(35, 30)`.
    @Test
    func mySQLKeepsAtMost30DigitsAfterThePoint() {
        let fine = rendered("numeric(40,35)", from: .postgres, to: .mysql)
        #expect(fine.spelling == "DECIMAL(35, 30)")
        #expect(fine.fidelity == .approximated)
        #expect(fine.reason != nil)

        #expect(spelling("numeric(70,40)", from: .postgres, to: .mysql) == "DECIMAL(65, 30)")
        #expect(spelling("numeric(38,-10)", from: .postgres, to: .mysql) == "DECIMAL(48, 0)")
        #expect(spelling("numeric(65,30)", from: .postgres, to: .mysql) == "DECIMAL(65, 30)")
        #expect(rendered("numeric(65,30)", from: .postgres, to: .mysql).fidelity == .exact)
    }

    /// Only MySQL has a scale ceiling below its precision; elsewhere a precision cut keeps the scale.
    @Test
    func aPrecisionCutKeepsTheScaleWhereTheEngineAllowsIt() {
        let fine = rendered("numeric(40,35)", from: .postgres, to: .mssql)
        #expect(fine.spelling == "DECIMAL(38, 35)")
        #expect(fine.fidelity == .approximated)
        #expect(spelling("numeric(38,-10)", from: .postgres, to: .mssql) == "DECIMAL(38, 0)")
        #expect(spelling("DECIMAL(65,30)", from: .mysql, to: .mssql) == "DECIMAL(38, 30)")
    }

    // MARK: - ClickHouse text

    /// `FixedString(n)` holds at most n bytes, and a padded PostgreSQL `char(20)` holding `José` is 21.
    @Test
    func fixedLengthTextReachesClickHouseAsString() {
        let padded = rendered("character(20)", from: .postgres, to: .clickhouse)
        #expect(padded.spelling == "String")
        #expect(padded.fidelity == .exact)
        #expect(spelling("CHAR(20)", from: .mysql, to: .clickhouse) == "String")
        #expect(spelling("NCHAR(10)", from: .mssql, to: .clickhouse) == "String")
    }

    // MARK: - Oracle character semantics

    /// A byte length refuses multibyte text an engine counting characters accepted, so the length
    /// says `CHAR` and a column whose four-byte worst case passes Oracle's byte ceiling moves up.
    @Test
    func oracleTextCountsCharactersWithinItsByteCeiling() {
        let text = { (length: Int, isFixed: Bool) in
            SQLTypeRenderer.render(
                CanonicalColumnType(kind: .text(length: length, isFixed: isFixed), sourceSpelling: "text"),
                family: .oracle
            )
        }
        #expect(text(1_000, false).spelling == "VARCHAR2(1000 CHAR)")
        #expect(text(1_001, false).spelling == "CLOB")
        #expect(text(1_001, false).fidelity == .widened)
        #expect(text(500, true).spelling == "CHAR(500 CHAR)")
        #expect(text(501, true).spelling == "VARCHAR2(501 CHAR)")
        #expect(SQLTypeParser.parse(text(1_000, false).spelling, family: .oracle).kind == .text(length: 1_000, isFixed: false))
    }
}
