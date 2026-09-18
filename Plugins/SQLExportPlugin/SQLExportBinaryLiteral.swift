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
/// An engine this does not name keeps `X''`, which is what the export has always written, so no
/// engine's output changes except the two measured to have been wrong.
internal enum SQLExportBinaryLiteral {
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
        switch SqlDialect.from(databaseTypeId: databaseTypeId) {
        case .postgres:
            return "decode('\(hex)', 'hex')"
        default:
            return "X'\(hex)'"
        }
    }

    /// `String(format: "%02X", byte)` per byte costs 557 ms for one mebibyte against 3.07 ms for this
    /// loop, measured with `swiftc -O` on arm64, and it allocates a `String` per byte plus the array
    /// holding them before the join. The export's own byte budget has to measure whatever this
    /// returns, and a binary column doubles its length here, so this is the hot path of exactly the
    /// wide-row table the budget exists for.
    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    internal static func hexString(_ data: Data) -> String {
        var characters: [UInt8] = []
        characters.reserveCapacity(data.count * 2)
        for byte in data {
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }
}
