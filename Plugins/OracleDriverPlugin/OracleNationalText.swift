//
//  OracleNationalText.swift
//  OracleDriverPlugin
//

import Foundation

/// Text for an NCHAR, NVARCHAR2 or NCLOB column, written so it reaches the column whatever the database character set.
///
/// A string literal and a CHAR or VARCHAR bind pass through the database character set before the national one, so on
/// a WE8MSWIN1252 database Lao text was stored as `¿¿¿` with no error, and a row match on it found the wrong row
/// (measured on 23ai). `UNISTR` carries each character as ASCII or a `\XXXX` UTF-16 escape, which the server turns
/// straight into the national character set. Text that is all ASCII is in every database character set and keeps its
/// plain literal.
internal enum OracleNationalText {
    /// The most a UNISTR argument may hold. It is a string literal: 800 escapes parse, 801 fail with ORA-01704.
    static let maxChunkBytes = 4_000

    /// The most a UNISTR result may hold: it is an NVARCHAR2, and past 4,000 bytes an AL16UTF16 database cut it short
    /// with no error (3,995 `a` and an `é` read back 2,000 characters, measured on 23ai). Each character is counted at
    /// its widest under either national character set: 2 bytes for ASCII, 3 for every other UTF-16 unit.
    static let maxChunkNationalBytes = 4_000

    /// The text as `UNISTR` calls joined with `||`, each within both limits above and wrapped in `TO_NCLOB` for an
    /// NCLOB so the joined value is not held to 4,000 bytes (ORA-01489), or nil when the text is all ASCII. NUL
    /// characters are dropped, as the plain literal drops them.
    static func sql(for text: String, asLOB: Bool) -> String? {
        let scalars = text.unicodeScalars.filter { $0 != "\0" }
        guard scalars.contains(where: { !$0.isASCII }) else { return nil }
        var chunks: [String] = []
        var chunk = ""
        var chunkBytes = 0
        var chunkNationalBytes = 0
        for scalar in scalars {
            let piece = escaped(scalar)
            let nationalBytes = scalar.isASCII ? 2 : 3 * String(scalar).utf16.count
            if chunkBytes + piece.utf8.count > maxChunkBytes
                || chunkNationalBytes + nationalBytes > maxChunkNationalBytes {
                chunks.append(chunk)
                chunk = ""
                chunkBytes = 0
                chunkNationalBytes = 0
            }
            chunk += piece
            chunkBytes += piece.utf8.count
            chunkNationalBytes += nationalBytes
        }
        chunks.append(chunk)
        return chunks
            .map { asLOB ? "TO_NCLOB(UNISTR('\($0)'))" : "UNISTR('\($0)')" }
            .joined(separator: " || ")
    }

    /// One character as UNISTR takes it: printable ASCII as itself, a quote doubled, a backslash as `\\`, and anything
    /// else as one `\XXXX` per UTF-16 unit. Both halves of a surrogate pair come back together, so a chunk never splits
    /// a character.
    private static func escaped(_ scalar: Unicode.Scalar) -> String {
        switch scalar {
        case "'":
            return "''"
        case "\\":
            return "\\\\"
        case " "..."~":
            return String(scalar)
        default:
            return String(scalar).utf16.map { String(format: "\\%04X", $0) }.joined()
        }
    }
}
