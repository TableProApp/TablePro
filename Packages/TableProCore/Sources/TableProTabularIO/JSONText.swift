import Foundation

public enum JSONText {
    private static let replacementCharacter: UInt32 = 0xFFFD

    public static func decodedString(_ content: UnsafeBufferPointer<UInt8>) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(content.count)
        appendDecoded(content, into: &output)
        return output.withUnsafeBufferPointer(lossyString)
    }

    public static func lossyString(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }

    public static func appendDecoded(_ content: UnsafeBufferPointer<UInt8>, into output: inout [UInt8]) {
        let count = content.count
        var index = 0
        while index < count {
            var runEnd = index
            while runEnd < count, content[runEnd] != JSONByte.backslash {
                runEnd += 1
            }
            if runEnd > index {
                output.append(contentsOf: UnsafeBufferPointer(rebasing: content[index..<runEnd]))
            }
            index = runEnd + 1
            guard index < count else { return }
            let escape = content[index]
            index += 1
            switch escape {
            case JSONByte.quote, JSONByte.backslash, JSONByte.slash:
                output.append(escape)
            case JSONByte.letterB:
                output.append(JSONByte.backspace)
            case JSONByte.letterF:
                output.append(JSONByte.formFeed)
            case JSONByte.letterN:
                output.append(JSONByte.lineFeed)
            case JSONByte.letterR:
                output.append(JSONByte.carriageReturn)
            case JSONByte.letterT:
                output.append(JSONByte.tab)
            case JSONByte.letterU:
                index = appendUnicodeEscape(content, from: index, into: &output)
            default:
                output.append(JSONByte.backslash)
                output.append(escape)
            }
        }
    }

    public static func appendCompact(_ bytes: UnsafeBufferPointer<UInt8>, into output: inout [UInt8]) {
        let count = bytes.count
        var index = 0
        var runStart = 0
        while index < count {
            let byte = bytes[index]
            if byte == JSONByte.quote {
                index = endOfString(bytes, from: index + 1)
                continue
            }
            guard JSONByte.isWhitespace(byte) else {
                index += 1
                continue
            }
            if index > runStart {
                output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[runStart..<index]))
            }
            index += 1
            runStart = index
        }
        let end = min(index, count)
        if end > runStart {
            output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[runStart..<end]))
        }
    }

    public static func compact(_ text: String) -> String {
        var copy = text
        var output: [UInt8] = []
        copy.withUTF8 { appendCompact($0, into: &output) }
        return output.withUnsafeBufferPointer(lossyString)
    }

    public static func stringLiteral(_ text: String) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(text.utf8.count + 2)
        appendStringLiteral(text, into: &output)
        return output.withUnsafeBufferPointer(lossyString)
    }

    public static func appendStringLiteral(_ text: String, into output: inout [UInt8]) {
        output.append(JSONByte.quote)
        for byte in text.utf8 {
            switch byte {
            case JSONByte.quote, JSONByte.backslash:
                output.append(JSONByte.backslash)
                output.append(byte)
            case JSONByte.lineFeed:
                output.append(contentsOf: [JSONByte.backslash, JSONByte.letterN])
            case JSONByte.carriageReturn:
                output.append(contentsOf: [JSONByte.backslash, JSONByte.letterR])
            case JSONByte.tab:
                output.append(contentsOf: [JSONByte.backslash, JSONByte.letterT])
            case JSONByte.backspace:
                output.append(contentsOf: [JSONByte.backslash, JSONByte.letterB])
            case JSONByte.formFeed:
                output.append(contentsOf: [JSONByte.backslash, JSONByte.letterF])
            case 0x00..<JSONByte.space:
                output.append(contentsOf: [JSONByte.backslash, JSONByte.letterU, JSONByte.zero, JSONByte.zero])
                output.append(contentsOf: [hexDigit(byte >> 4), hexDigit(byte & 0x0F)])
            default:
                output.append(byte)
            }
        }
        output.append(JSONByte.quote)
    }

    private static func endOfString(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        let count = bytes.count
        var index = start
        while index < count {
            let byte = bytes[index]
            if byte == JSONByte.backslash {
                index += 2
                continue
            }
            index += 1
            if byte == JSONByte.quote { return index }
        }
        return count
    }

    internal static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39:
            return UInt32(byte - 0x30)
        case 0x41...0x46:
            return UInt32(byte - 0x41 + 10)
        case 0x61...0x66:
            return UInt32(byte - 0x61 + 10)
        default:
            return nil
        }
    }

    private static func hexDigit(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? 0x30 + nibble : 0x61 + nibble - 10
    }

    private static func codeUnit(_ content: UnsafeBufferPointer<UInt8>, at index: Int) -> UInt32? {
        guard index + 4 <= content.count else { return nil }
        var value: UInt32 = 0
        for offset in 0..<4 {
            guard let digit = hexValue(content[index + offset]) else { return nil }
            value = value << 4 | digit
        }
        return value
    }

    private static func appendUnicodeEscape(
        _ content: UnsafeBufferPointer<UInt8>,
        from index: Int,
        into output: inout [UInt8]
    ) -> Int {
        guard let unit = codeUnit(content, at: index) else {
            appendScalar(replacementCharacter, into: &output)
            return index
        }
        let afterUnit = index + 4
        switch unit {
        case 0xD800...0xDBFF:
            let hasLowEscape = afterUnit + 1 < content.count
                && content[afterUnit] == JSONByte.backslash
                && content[afterUnit + 1] == JSONByte.letterU
            guard hasLowEscape, let low = codeUnit(content, at: afterUnit + 2), (0xDC00...0xDFFF).contains(low) else {
                appendScalar(replacementCharacter, into: &output)
                return afterUnit
            }
            appendScalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00), into: &output)
            return afterUnit + 6
        case 0xDC00...0xDFFF:
            appendScalar(replacementCharacter, into: &output)
            return afterUnit
        default:
            appendScalar(unit, into: &output)
            return afterUnit
        }
    }

    private static func appendScalar(_ scalar: UInt32, into output: inout [UInt8]) {
        switch scalar {
        case ..<0x80:
            output.append(UInt8(scalar))
        case ..<0x800:
            output.append(UInt8(0xC0 | (scalar >> 6)))
            output.append(UInt8(0x80 | (scalar & 0x3F)))
        case ..<0x10000:
            output.append(UInt8(0xE0 | (scalar >> 12)))
            output.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            output.append(UInt8(0x80 | (scalar & 0x3F)))
        default:
            output.append(UInt8(0xF0 | (scalar >> 18)))
            output.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
            output.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            output.append(UInt8(0x80 | (scalar & 0x3F)))
        }
    }
}
