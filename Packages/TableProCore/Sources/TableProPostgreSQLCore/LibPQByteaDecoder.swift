//
//  LibPQByteaDecoder.swift
//  PostgreSQLDriverPlugin
//
//  Decodes PostgreSQL BYTEA values from libpq's text result format into raw Data.
//
//  PostgreSQL emits BYTEA in one of two text formats, controlled by the server's
//  bytea_output GUC:
//
//  1. HEX  (default since 9.0): "\xd38ce566..."
//        Two-character prefix \x followed by 2*N lowercase or uppercase hex digits.
//
//  2. ESCAPE  (legacy, still emitted by some servers and dump tools):
//        Printable ASCII bytes are emitted literally except for these escapes:
//          \\          → 0x5C  (literal backslash)
//          \nnn        → byte with that octal value (0-377)
//        All other bytes (including 0x00) are emitted as \nnn.
//
//  The full spec lives at:
//        https://www.postgresql.org/docs/current/datatype-binary.html
//

import Foundation

enum LibPQByteaDecoder {
    /// Decodes a BYTEA text representation as returned by libpq's text result format
    /// into raw bytes.
    ///
    /// - Parameter text: The BYTEA value as libpq emitted it (e.g. "\\xd38ce566..." or
    ///   "\\\\012abc").
    /// - Returns: The decoded raw bytes, or nil if `text` is not a valid BYTEA
    ///   text representation in either supported format.
    static func decode(_ text: String) -> Data? {
        if text.isEmpty {
            return Data()
        }

        let utf8 = Array(text.utf8)

        // Hex format: \xHHHH...  (lowercase per PG docs, but accept uppercase too)
        if utf8.count >= 2, utf8[0] == 0x5C, utf8[1] == 0x78 || utf8[1] == 0x58 {
            let hexBytes = utf8.dropFirst(2)
            guard hexBytes.count % 2 == 0 else { return nil }
            var data = Data()
            data.reserveCapacity(hexBytes.count / 2)
            var iterator = hexBytes.makeIterator()
            while let high = iterator.next(), let low = iterator.next() {
                guard let h = hexNibble(high), let l = hexNibble(low) else { return nil }
                data.append((h << 4) | l)
            }
            return data
        }

        // Escape format: walk bytes; \\ → 0x5C, \nnn (3 octal digits) → byte, others literal.
        var data = Data()
        data.reserveCapacity(utf8.count)
        var i = 0
        while i < utf8.count {
            let byte = utf8[i]
            if byte == 0x5C {
                guard i + 1 < utf8.count else { return nil }
                let next = utf8[i + 1]
                if next == 0x5C {
                    data.append(0x5C)
                    i += 2
                    continue
                }
                guard i + 3 < utf8.count else { return nil }
                let d0 = utf8[i + 1]
                let d1 = utf8[i + 2]
                let d2 = utf8[i + 3]
                guard let n0 = octalNibble(d0),
                      let n1 = octalNibble(d1),
                      let n2 = octalNibble(d2) else { return nil }
                let value = (UInt16(n0) << 6) | (UInt16(n1) << 3) | UInt16(n2)
                guard value <= 0xFF else { return nil }
                data.append(UInt8(value))
                i += 4
            } else {
                data.append(byte)
                i += 1
            }
        }
        return data
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30          // 0-9
        case 0x41...0x46: return byte - 0x41 + 10     // A-F
        case 0x61...0x66: return byte - 0x61 + 10     // a-f
        default: return nil
        }
    }

    private static func octalNibble(_ byte: UInt8) -> UInt8? {
        guard byte >= 0x30, byte <= 0x37 else { return nil }
        return byte - 0x30
    }

    /// Encodes raw bytes back to BYTEA hex text format for inclusion in SQL literals.
    ///
    /// Produces the canonical `\xHHHH...` representation suitable for use in
    /// `'\xHHHH...'::bytea` or `E'\\xHHHH...'` SQL literals.
    static func encodeHexText(_ data: Data) -> String {
        var out = "\\x"
        out.reserveCapacity(2 + data.count * 2)
        for byte in data {
            out.append(String(format: "%02x", byte))
        }
        return out
    }
}
