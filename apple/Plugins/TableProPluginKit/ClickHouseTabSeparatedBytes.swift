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

    /// Calls `body` with each line of `bytes`, the part after the last separator included, until it returns false.
    /// The lines are views into `bytes`; nothing is copied.
    static func forEachLine(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ body: (UnsafeBufferPointer<UInt8>) -> Bool
    ) {
        forEachPart(of: bytes, separatedBy: lineSeparator, body)
    }

    /// Calls `body` with each field of `line`, in order, as a view into it.
    static func forEachField(_ line: UnsafeBufferPointer<UInt8>, _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        forEachPart(of: line, separatedBy: fieldSeparator) { field in
            body(field)
            return true
        }
    }

    static func isNullMarker(_ field: UnsafeBufferPointer<UInt8>) -> Bool {
        field.count == 2 && field[0] == backslash && field[1] == nullMarkerSuffix
    }

    /// A field as the grid holds it: text when its bytes are UTF-8, else the bytes. A field with no escape becomes
    /// its `String` in one copy; only one that holds a backslash is unescaped into a buffer first.
    static func cellValue(_ field: UnsafeBufferPointer<UInt8>, writesLiteralSyntax: Bool) -> PluginCellValue {
        if isNullMarker(field) { return .null }
        if writesLiteralSyntax || !contains(backslash, in: field) {
            return text(field).map(PluginCellValue.text) ?? .bytes(Data(field))
        }
        let unescaped = unescape(field)
        return unescaped.withUnsafeBufferPointer { text($0) }.map(PluginCellValue.text) ?? .bytes(Data(unescaped))
    }

    /// The bytes as a `String` when they are UTF-8, kept exactly as sent: a leading byte order mark is part of the
    /// value, which `String(bytes:encoding:)` would drop.
    static func text(_ bytes: UnsafeBufferPointer<UInt8>) -> String? {
        // A repaired decode differs from the bytes, so only valid UTF-8 comes back.
        let decoded = String(decoding: bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        return decoded.utf8.elementsEqual(bytes) ? decoded : nil
    }

    static func isAsciiWhitespace(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        bytes.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D || $0 == 0x0B || $0 == 0x0C }
    }

    // An Array, Map, Tuple or Nested value is written in ClickHouse's literal syntax with no TSV escaping over it,
    // so `['it\'s']` is already the value's text and unescaping it reads `['it's']`. Measured on ClickHouse 25.8.
    static func writesLiteralSyntax(_ columnType: String) -> Bool {
        var type = Substring(columnType)
        for wrapper in ["LowCardinality(", "Nullable("] where type.hasPrefix(wrapper) {
            type = type.dropFirst(wrapper.count)
        }
        return ["Array(", "Map(", "Tuple(", "Nested("].contains { type.hasPrefix($0) }
    }

    /// The escape table ClickHouse's own `writeEscapedString` emits. An unrecognised escape keeps
    /// both of its bytes: a future addition then reads oddly rather than losing the character.
    static func unescape(_ field: ArraySlice<UInt8>) -> [UInt8] {
        field.withUnsafeBufferPointer { unescape($0) }
    }

    static func unescape(_ field: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        guard contains(backslash, in: field) else { return Array(field) }

        var result: [UInt8] = []
        result.reserveCapacity(field.count)
        var index = 0

        while index < field.count {
            let byte = field[index]
            guard byte == backslash else {
                result.append(byte)
                index += 1
                continue
            }
            let next = index + 1
            guard next < field.count else {
                result.append(backslash)
                break
            }
            if let decoded = escapedByte(field[next]) {
                result.append(decoded)
            } else {
                result.append(backslash)
                result.append(field[next])
            }
            index = next + 1
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
    static func headerText(_ field: UnsafeBufferPointer<UInt8>) -> String {
        String(decoding: unescape(field), as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }

    static func headerTexts(_ line: UnsafeBufferPointer<UInt8>) -> [String] {
        var texts: [String] = []
        forEachField(line) { texts.append(headerText($0)) }
        return texts
    }

    private static func contains(_ byte: UInt8, in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return false }
        return memchr(base, Int32(byte), bytes.count) != nil
    }

    private static func forEachPart(
        of bytes: UnsafeBufferPointer<UInt8>,
        separatedBy separator: UInt8,
        _ body: (UnsafeBufferPointer<UInt8>) -> Bool
    ) {
        guard let base = bytes.baseAddress else {
            _ = body(bytes)
            return
        }
        var start = 0
        while start <= bytes.count {
            let remaining = bytes.count - start
            let found = remaining > 0 ? memchr(base + start, Int32(separator), remaining) : nil
            let end = found.map { UnsafeRawPointer($0) - UnsafeRawPointer(base) } ?? bytes.count
            guard body(UnsafeBufferPointer(rebasing: bytes[start..<end])) else { return }
            guard found != nil else { return }
            start = end + 1
        }
    }
}
