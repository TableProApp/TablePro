//
//  SQLExportBinaryLiteralTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// `X'4142'` is three different things across the engines this export writes for, and on PostgreSQL
/// it is a bit string rather than binary. Measured on PostgreSQL 17.11:
/// `INSERT INTO b (payload) VALUES (X'414243')` answers
/// `column "payload" is of type bytea but expression is of type bit`.
@Suite("SQL export binary literals")
struct SQLExportBinaryLiteralTests {
    private let sample = Data([0x41, 0x42, 0x43])

    @Test("MySQL and SQLite keep the hex literal they have always taken")
    func hexLiteralEnginesAreUnchanged() {
        for typeId in ["MySQL", "MariaDB", "TiDB", "SQLite", "libSQL", "Turso", "DuckDB", "Cloudflare D1"] {
            #expect(SQLExportBinaryLiteral.render(sample, databaseTypeId: typeId) == "X'414243'")
        }
    }

    /// `decode` rather than `'\x414243'::bytea` because the backslash form's meaning depends on
    /// `standard_conforming_strings`, which this dump never sets. Measured on PostgreSQL 17.11 with
    /// it off: the cast form stored `\x4134323433` and reported success, so the restore wrote
    /// different bytes and raised nothing.
    @Test("Every PostgreSQL-family engine gets decode, which means the same under either escape mode")
    func postgresUsesDecode() {
        for typeId in ["PostgreSQL", "Greenplum", "AlloyDB", "Citus", "CockroachDB", "PGlite", "Redshift"] {
            #expect(SQLExportBinaryLiteral.render(sample, databaseTypeId: typeId) == "decode('414243', 'hex')")
        }
    }

    @Test("SQL Server takes a 0x constant")
    func sqlServerUsesAHexConstant() {
        #expect(SQLExportBinaryLiteral.render(sample, databaseTypeId: "SQL Server") == "0x414243")
        #expect(SQLExportBinaryLiteral.render(Data(), databaseTypeId: "SQL Server") == "0x")
    }

    /// Measured on Oracle AI Database 26ai Free: `X'414243'` is `ORA-00917: missing comma`, and
    /// `HEXTORAW('414243')` is accepted into `BLOB`, `RAW(2000)` and `LONG RAW` alike, so one
    /// spelling serves every binary type and the column's own type need not be consulted.
    @Test("Oracle takes HEXTORAW, which it accepts for every binary type")
    func oracleUsesHextoraw() {
        #expect(SQLExportBinaryLiteral.render(sample, databaseTypeId: "Oracle") == "HEXTORAW('414243')")
    }

    /// `HEXTORAW('')` stores NULL, and into a `BLOB NOT NULL` it is `ORA-01400: cannot insert NULL`.
    /// An empty BLOB is not a null one, so the empty case is its own spelling. Measured:
    /// `EMPTY_BLOB()` stores length 0 and is accepted by `BLOB`, `BLOB NOT NULL` and `RAW(2000)`.
    @Test("An empty Oracle value is EMPTY_BLOB, which stores nothing rather than NULL")
    func oracleEmptyValueIsNotNull() {
        #expect(SQLExportBinaryLiteral.render(Data(), databaseTypeId: "Oracle") == "EMPTY_BLOB()")
    }

    /// Hex doubles the payload and Oracle caps a string literal at 4,000 characters, so `HEXTORAW`
    /// carries 2,000 binary bytes: measured, 2,000 stored 2,000 and 2,001 is `ORA-01704: string
    /// literal too long`. Nothing can express one past that in a single statement, so it is written
    /// anyway and counted, and the export names how many rather than reporting a clean dump.
    @Test("A value past Oracle's literal ceiling is flagged, and only on Oracle")
    func oracleLiteralCeilingIsReported() {
        let atCeiling = Data(repeating: 0xAB, count: SQLExportBinaryLiteral.oracleLiteralByteCeiling)
        let overCeiling = Data(repeating: 0xAB, count: SQLExportBinaryLiteral.oracleLiteralByteCeiling + 1)

        #expect(SQLExportBinaryLiteral.oracleLiteralByteCeiling == 2_000)
        #expect(!SQLExportBinaryLiteral.exceedsLiteralCeiling(atCeiling, databaseTypeId: "Oracle"))
        #expect(SQLExportBinaryLiteral.exceedsLiteralCeiling(overCeiling, databaseTypeId: "Oracle"))
        #expect(!SQLExportBinaryLiteral.exceedsLiteralCeiling(Data(), databaseTypeId: "Oracle"))

        /// No other engine has this ceiling, so none of them may be counted against it.
        for typeId in ["MySQL", "PostgreSQL", "SQLite", "SQL Server", "Dameng"] {
            #expect(!SQLExportBinaryLiteral.exceedsLiteralCeiling(overCeiling, databaseTypeId: typeId))
        }
    }

    /// An engine whose spelling has not been verified keeps what the export already wrote, so this
    /// change cannot regress one.
    @Test("An unlisted engine keeps the hex literal")
    func unlistedEnginesFallBackToHex() {
        for typeId in ["Snowflake", "Trino", "ClickHouse", "Teradata", "SomeFuturePlugin"] {
            #expect(SQLExportBinaryLiteral.render(sample, databaseTypeId: typeId) == "X'414243'")
        }
    }

    /// The encoder is rebuilt whenever a stream emits another header, and only the last one used to
    /// reach the export's tally, so a value over the ceiling in an earlier segment was dropped from
    /// the count and an export whose last segment held none reported clean.
    @Test("Each segment's unrepresentable values are counted, not just the last one's")
    func everySegmentsCountIsKept() {
        let over = Data(repeating: 0xAB, count: SQLExportBinaryLiteral.oracleLiteralByteCeiling + 1)
        func encoder() -> SQLExportRowValueEncoder {
            SQLExportRowValueEncoder(
                columns: ["payload"], columnTypeNames: ["BLOB"], excludedColumnNames: [],
                databaseTypeId: "Oracle", escapeStringLiteral: { $0 })
        }

        let first = encoder()
        _ = first.render([.bytes(over)])
        let second = encoder()
        _ = second.render([.text("small")])

        #expect(first.unrepresentableValues.total == 1)
        #expect(second.unrepresentableValues.total == 0, "a fresh segment starts its own count")

        var tally = SQLExportStatementTally()
        tally.unrepresentableValues += first.unrepresentableValues.total
        tally.unrepresentableValues += second.unrepresentableValues.total
        #expect(tally.unrepresentableValues == 1, "the earlier segment's value must survive")
    }

    @Test("The hex is uppercase, two characters per byte, for every byte value")
    func hexCoversEveryByte() {
        #expect(SQLExportBinaryLiteral.hexString(Data()) == "")
        #expect(SQLExportBinaryLiteral.hexString(Data([0x00])) == "00")
        #expect(SQLExportBinaryLiteral.hexString(Data([0xFF])) == "FF")
        #expect(SQLExportBinaryLiteral.hexString(Data([0x0F, 0xF0])) == "0FF0")

        let everyByte = Data((0 ... 255).map { UInt8($0) })
        let hex = SQLExportBinaryLiteral.hexString(everyByte)
        #expect(hex.utf8.count == 512)
        #expect(hex == everyByte.map { String(format: "%02X", $0) }.joined())
    }

    /// A driver hands back slices of a larger buffer, whose indices do not start at zero. A loop
    /// that indexed the `Data` rather than iterating it would read the wrong bytes or trap.
    @Test("A slice of a larger buffer renders its own bytes")
    func slicesRenderTheirOwnBytes() {
        let backing = Data((0 ..< 300).map { UInt8($0 % 256) })
        let slice = backing[100 ..< 104]
        #expect(SQLExportBinaryLiteral.hexString(slice) == "64656667")
    }
}
