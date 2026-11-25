//
//  SQLExportBinaryLiteral.swift
//  SQLExportPlugin
//

import Foundation
import TableProPluginKit

/// The literal an engine reads back as the binary value it was given.
///
/// `X'4142'` is not portable. PostgreSQL parses it as a *bit string*, so a `bytea` column rejects it
/// with `column "payload" is of type bytea but expression is of type bit`, and every dump carrying a
/// binary value failed to restore there. SQL Server spells the same value `0x4142`. Measured on
/// PostgreSQL 17.11.
///
/// PostgreSQL takes `decode('4142', 'hex')` rather than `'\x4142'::bytea` on purpose, and the reason
/// is worse than a syntax error. The backslash form's meaning depends on `standard_conforming_strings`,
/// which this dump does not set: measured with it `off`, `'\x414243'::bytea` stored
/// `\x4134323433` and reported success, so the restore wrote different bytes and said nothing.
/// `decode` means the same thing under either setting.
///
/// Oracle takes `HEXTORAW`, and an empty value takes `EMPTY_BLOB()` instead. Measured on Oracle AI
/// Database 26ai Free 23.26.3.0.0, `max_string_size = STANDARD`:
///
/// - `X'414243'` is `ORA-00917: missing comma`. Oracle has no such literal.
/// - `HEXTORAW('414243')` is accepted into `BLOB`, `RAW(2000)` and `LONG RAW` alike, so one
///   spelling serves all three and the column's own type does not have to be consulted.
/// - `HEXTORAW('')` stores NULL, and into a `BLOB NOT NULL` it is `ORA-01400: cannot insert NULL`.
///   An empty BLOB is not a null one, so the empty case is its own: `EMPTY_BLOB()` stores length 0
///   and is accepted by `BLOB`, `BLOB NOT NULL` and `RAW(2000)`.
/// - Hex doubles the payload and a string literal caps at 4,000 bytes, so `HEXTORAW` carries 2,000
///   binary bytes: 2,000 stored 2,000, and 2,001 is `ORA-01704: string literal too long`.
///
/// Nothing can be written for a value past that ceiling, because no single-statement Oracle
/// representation of one exists. It is still written as `HEXTORAW`, which a server configured
/// `max_string_size = EXTENDED` accepts up to 16,383 bytes, and `SQLExportRowValueEncoder` counts it
/// so the export reports how many values it could not promise rather than claiming a clean dump.
///
/// DuckDB reads `X'4142'` as the text `x4142` and stores those bytes, so a restore wrote different
/// bytes and reported success. `from_hex('4142')` is the BLOB itself. Measured on DuckDB 1.5.2.
///
/// An engine this does not name keeps `X''`, which is what the export has always written, so no
/// engine's output changes except the three measured to have been wrong.
nonisolated internal enum SQLExportBinaryLiteral {
    /// The most binary bytes Oracle can carry in one `HEXTORAW` literal: 4,000 characters of hex,
    /// two per byte. Measured, not inferred.
    internal static let oracleLiteralByteCeiling = 2_000

    /// True for a value this engine cannot represent in one statement, whatever spelling is used.
    internal static func exceedsLiteralCeiling(_ data: Data, databaseTypeId: String) -> Bool {
        databaseTypeId == "Oracle" && data.count > oracleLiteralByteCeiling
    }

    internal static func render(_ data: Data, databaseTypeId: String) -> String {
        let hex = hexString(data)
        if databaseTypeId == "SQL Server" {
            return "0x\(hex)"
        }
        if databaseTypeId == "Oracle" {
            return data.isEmpty ? "EMPTY_BLOB()" : "HEXTORAW('\(hex)')"
        }
        if databaseTypeId == "DuckDB" {
            return "from_hex('\(hex)')"
        }
        switch SqlDialect.from(databaseTypeId: databaseTypeId) {
        case .postgres:
            // KingbaseES documents `decode` only as Oracle's DECODE, and Redshift has no bytea and reads
            // VARBYTE, so both reject `decode('<hex>','hex')`. Spellings measured in the app's
            // CompareSQLLiteral.postgresFamilyBinaryLiteral.
            if databaseTypeId == "KingbaseES" { return "'\\x\(hex)'::bytea" }
            if databaseTypeId == "Redshift" { return "from_hex('\(hex)')" }
            return "decode('\(hex)', 'hex')"
        default:
            return "X'\(hex)'"
        }
    }

    internal static func hexString(_ data: Data) -> String {
        PluginHexText.uppercase(data)
    }
}
