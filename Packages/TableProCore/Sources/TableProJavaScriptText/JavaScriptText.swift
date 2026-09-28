//
//  JavaScriptText.swift
//  TableProJavaScriptText
//

import Foundation

/// Shell text written around a name the server chose, each piece escaped for where it stands.
///
/// JSON only requires the C0 controls to be escaped inside a string. JavaScript also ends a line
/// at U+2028 and U+2029, and the editor's statement scanner ends one wherever
/// `Character.isNewline` does, which adds U+0085, VT and FF. Written raw, any of them ended the
/// comment or the string around a name early, and the rest of the name was read as script.
public enum JavaScriptText {
    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")

    /// The escape for a character that ends a line or cannot be seen, or nil for any other.
    public static func lineBreakingEscape(_ scalar: Unicode.Scalar) -> String? {
        switch scalar {
        case "\n": return "\\n"
        case "\r": return "\\r"
        case "\t": return "\\t"
        default:
            let value = scalar.value
            guard value < 0x20 || (0x7F ... 0x9F).contains(value) || value == 0x2028 || value == 0x2029 else {
                return nil
            }
            return String(format: "\\u%04x", value)
        }
    }

    /// A double-quoted string literal on one line, which JSON and JavaScript both read back as `value`.
    public static func stringLiteral(_ value: String) -> String {
        var output: [UInt8] = [quote]
        output.reserveCapacity(value.utf8.count + 2)
        let wasContiguous = value.utf8.withContiguousStorageIfAvailable { appendEscaped($0, to: &output) } != nil
        if !wasContiguous {
            Array(value.utf8).withUnsafeBufferPointer { appendEscaped($0, to: &output) }
        }
        output.append(quote)
        return String(decoding: output, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }

    /// A `//` comment that ends where its own line does.
    public static func lineComment(_ text: String) -> String {
        var line = "//"
        guard !text.isEmpty else { return line }
        line.append(" ")
        for scalar in text.unicodeScalars {
            if let escape = lineBreakingEscape(scalar) {
                line.append(escape)
            } else {
                line.unicodeScalars.append(scalar)
            }
        }
        return line
    }

    /// Whether `name` can follow a `.` as it is: ASCII letters, digits and `_`, not led by a digit.
    ///
    /// Checked byte by byte, because a `Character` is a whole grapheme cluster, and a Unicode
    /// Prepend letter joined to a `(` or `;` answers `isLetter` for the pair.
    public static func isPlainIdentifier(_ name: String) -> Bool {
        guard let first = name.utf8.first, !isASCIIDigit(first) else { return false }
        return name.utf8.allSatisfy { isASCIILetter($0) || isASCIIDigit($0) || $0 == UInt8(ascii: "_") }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
    }

    /// Runs on the UTF-8 bytes, because an export calls it once per value and a loop over
    /// `unicodeScalars` measured twice as slow. Every other byte is copied as it is.
    private static func appendEscaped(_ bytes: UnsafeBufferPointer<UInt8>, to output: inout [UInt8]) {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == quote || byte == backslash {
                output.append(backslash)
                output.append(byte)
                index += 1
            } else if let sequence = escapableSequence(in: bytes, at: index),
                      let escape = lineBreakingEscape(sequence.scalar) {
                output.append(contentsOf: escape.utf8)
                index += sequence.width
            } else {
                output.append(byte)
                index += 1
            }
        }
    }

    /// The character at `index` when its lead byte is one that can spell a character
    /// `lineBreakingEscape` answers for: a C0 control or DEL, 0xC2 for U+0080 to U+00BF, or 0xE2
    /// for U+2000 to U+2FFF. A Swift string is valid UTF-8, so the continuation bytes are there.
    private static func escapableSequence(
        in bytes: UnsafeBufferPointer<UInt8>,
        at index: Int
    ) -> (scalar: Unicode.Scalar, width: Int)? {
        let lead = bytes[index]
        switch lead {
        case 0x00 ..< 0x20, 0x7F:
            return (Unicode.Scalar(lead), 1)
        case 0xC2 where index + 1 < bytes.count:
            return (Unicode.Scalar(bytes[index + 1]), 2)
        case 0xE2 where index + 2 < bytes.count:
            let value = 0x2000 | UInt32(bytes[index + 1] & 0x3F) << 6 | UInt32(bytes[index + 2] & 0x3F)
            return Unicode.Scalar(value).map { (scalar: $0, width: 3) }
        default:
            return nil
        }
    }
}
