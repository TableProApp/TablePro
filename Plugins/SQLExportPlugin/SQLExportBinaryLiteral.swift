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
/// Oracle is deliberately left on `X''`, which it rejects, rather than moved to `HEXTORAW`. Hex
/// doubles the payload and Oracle caps a string literal at 4,000 bytes, so `HEXTORAW` carries 2,000
/// binary bytes and no more; past that the statement is still far under any size limit, so it would
/// export clean and fail the restore with nothing said. `HEXTORAW('')` is NULL under Oracle's
/// empty-string rule, which an empty BLOB is not, and `RAW`, `LONG RAW` and `BLOB` do not share one
/// correct spelling. Rejected loudly beats accepted and wrong; a column-aware Oracle path needs an
/// Oracle to measure against.
///
/// An engine this does not name keeps `X''`, which is what the export has always written, so no
/// engine's output changes except the two measured or documented to have been wrong.
internal enum SQLExportBinaryLiteral {
    internal static func render(_ data: Data, databaseTypeId: String) -> String {
        let hex = hexString(data)
        if databaseTypeId == "SQL Server" {
            return "0x\(hex)"
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
