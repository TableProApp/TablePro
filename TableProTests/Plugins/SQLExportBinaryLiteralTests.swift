//
//  SQLExportBinaryLiteralTests.swift
//  TableProTests
//

import Foundation
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

    /// Oracle stays on the literal it rejects rather than moving to `HEXTORAW`, which carries 2,000
    /// binary bytes at most and would export clean and fail the restore above that.
    @Test("Oracle is left on the literal it rejects rather than one that fails silently")
    func oracleIsLeftAlone() {
        #expect(SQLExportBinaryLiteral.render(sample, databaseTypeId: "Oracle") == "X'414243'")
    }

    /// An engine whose spelling has not been verified keeps what the export already wrote, so this
    /// change cannot regress one.
    @Test("An unlisted engine keeps the hex literal")
    func unlistedEnginesFallBackToHex() {
        for typeId in ["Snowflake", "Trino", "ClickHouse", "Dameng", "Teradata", "SomeFuturePlugin"] {
            #expect(SQLExportBinaryLiteral.render(sample, databaseTypeId: typeId) == "X'414243'")
        }
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
