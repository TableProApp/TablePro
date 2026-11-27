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

public enum LibPQByteaDecoder {
    public static func decode(_ text: String) -> Data? {
        var text = text
        return text.withUTF8 { decode(bytes: UnsafeRawBufferPointer($0)) }
    }

    // Reads libpq's buffer as it arrived: a value is never valid UTF-8 text to begin with.
    public static func decode(bytes: UnsafeRawBufferPointer) -> Data? {
        if bytes.isEmpty {
            return Data()
        }
        if bytes.count >= 2, bytes[0] == 0x5C, bytes[1] == 0x78 || bytes[1] == 0x58 {
            return decodeHex(UnsafeRawBufferPointer(rebasing: bytes[2...]))
        }
        return decodeEscape(bytes)
    }

    private static func decodeHex(_ digits: UnsafeRawBufferPointer) -> Data? {
        guard digits.count % 2 == 0 else { return nil }
        var data = Data(count: digits.count / 2)
        let isValid = data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) -> Bool in
            hexNibbles.withUnsafeBufferPointer { nibbles in
                var seen: UInt8 = 0
                var index = 0
                while index < output.count {
                    let high = nibbles[Int(digits[index * 2])]
                    let low = nibbles[Int(digits[index * 2 + 1])]
                    seen |= high | low
                    output[index] = (high << 4) | (low & 0x0F)
                    index += 1
                }
                return seen & invalidNibble == 0
            }
        }
        return isValid ? data : nil
    }

    // Walks bytes: \\ → 0x5C, \nnn (3 octal digits) → byte, others literal.
    private static func decodeEscape(_ bytes: UnsafeRawBufferPointer) -> Data? {
        var data = Data(count: bytes.count)
        let written = data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) -> Int? in
            var read = 0
            var written = 0
            while read < bytes.count {
                let byte = bytes[read]
                guard byte == 0x5C else {
                    output[written] = byte
                    written += 1
                    read += 1
                    continue
                }
                guard read + 1 < bytes.count else { return nil }
                if bytes[read + 1] == 0x5C {
                    output[written] = 0x5C
                    written += 1
                    read += 2
                    continue
                }
                guard read + 3 < bytes.count,
                      let high = octalDigit(bytes[read + 1]),
                      let middle = octalDigit(bytes[read + 2]),
                      let low = octalDigit(bytes[read + 3]) else { return nil }
                let value = (UInt16(high) << 6) | (UInt16(middle) << 3) | UInt16(low)
                guard value <= 0xFF else { return nil }
                output[written] = UInt8(value)
                written += 1
                read += 4
            }
            return written
        }
        guard let written else { return nil }
        data.count = written
        return data
    }

    private static let invalidNibble: UInt8 = 0x80

    private static let hexNibbles: [UInt8] = {
        var table = [UInt8](repeating: invalidNibble, count: 256)
        for (value, digit) in "0123456789".utf8.enumerated() { table[Int(digit)] = UInt8(value) }
        for (value, digit) in "abcdef".utf8.enumerated() { table[Int(digit)] = UInt8(value + 10) }
        for (value, digit) in "ABCDEF".utf8.enumerated() { table[Int(digit)] = UInt8(value + 10) }
        return table
    }()

    private static func octalDigit(_ byte: UInt8) -> UInt8? {
        guard byte >= 0x30, byte <= 0x37 else { return nil }
        return byte - 0x30
    }

    public static func encodeHexText(_ data: Data) -> String {
        var out = "\\x"
        out.reserveCapacity(2 + data.count * 2)
        for byte in data {
            out.append(String(format: "%02x", byte))
        }
        return out
    }
}
