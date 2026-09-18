import Foundation

/// ClickHouse writes `TabSeparated` as a byte stream, not as text. A `String` column is an
/// arbitrary byte sequence, and the only bytes the format escapes are the eight below, so a value
/// holding a hash, a protobuf or a lone `0xC3` reaches the client verbatim. Splitting and
/// unescaping therefore happen on bytes, and only a finished field is offered to a text decode.
internal enum ClickHouseTabSeparatedBytes {
    static let lineSeparator: UInt8 = 0x0A
    static let fieldSeparator: UInt8 = 0x09
    private static let backslash: UInt8 = 0x5C
    private static let nullMarkerSuffix: UInt8 = 0x4E

    static func lines(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        split(bytes[...], on: lineSeparator)
    }

    static func fields(_ line: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        split(line, on: fieldSeparator)
    }

    static func isNullMarker(_ field: ArraySlice<UInt8>) -> Bool {
        field.count == 2 && field.first == backslash && field.last == nullMarkerSuffix
    }

    static func isAsciiWhitespace(_ bytes: [UInt8]) -> Bool {
        bytes.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D || $0 == 0x0B || $0 == 0x0C }
    }

    /// The escape table ClickHouse's own `writeEscapedString` emits. An unrecognised escape keeps
    /// both of its bytes: a future addition then reads oddly rather than losing the character.
    static func unescape(_ field: ArraySlice<UInt8>) -> [UInt8] {
        guard field.contains(backslash) else { return Array(field) }

        var result: [UInt8] = []
        result.reserveCapacity(field.count)
        var index = field.startIndex

        while index < field.endIndex {
            let byte = field[index]
            guard byte == backslash else {
                result.append(byte)
                index = field.index(after: index)
                continue
            }
            let next = field.index(after: index)
            guard next < field.endIndex else {
                result.append(backslash)
                break
            }
            if let decoded = escapedByte(field[next]) {
                result.append(decoded)
            } else {
                result.append(backslash)
                result.append(field[next])
            }
            index = field.index(after: next)
        }

        return result
    }

    /// Nil when the byte after the backslash is not one ClickHouse escapes.
    static func escapedByte(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x5C: return 0x5C
        case 0x74: return 0x09
        case 0x6E: return 0x0A
        case 0x72: return 0x0D
        case 0x30: return 0x00
        case 0x62: return 0x08
        case 0x66: return 0x0C
        case 0x27: return 0x27
        default: return nil
        }
    }

    /// A header field has to become a `String`, so an undecodable byte is replaced rather than
    /// dropping the column. A value never takes this path; it stays bytes instead.
    static func headerText(_ field: ArraySlice<UInt8>) -> String {
        String(decoding: unescape(field), as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }

    private static func split(_ bytes: ArraySlice<UInt8>, on separator: UInt8) -> [ArraySlice<UInt8>] {
        var parts: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        var index = bytes.startIndex

        while index < bytes.endIndex {
            if bytes[index] == separator {
                parts.append(bytes[start..<index])
                start = bytes.index(after: index)
            }
            index = bytes.index(after: index)
        }
        parts.append(bytes[start..<bytes.endIndex])
        return parts
    }
}
