import Foundation
import TableProEditorKit

internal enum JsonReindenter {
    // The editor's own ceiling: past it the editor drops colors and folding, so indented text stops there too.
    private static let maxLength = EditorHighlighting.maxHighlightableCharacters
    private static let defaultIndent = "  "

    // Nil for invalid JSON, and for valid JSON whose indented text would pass the editor's ceiling.
    static func reindentIfValid(_ source: String, indent: String = defaultIndent) -> String? {
        guard (source as NSString).length <= maxLength else { return nil }
        return JsonLayoutWriter.write(source, indent: Array(indent.utf8), maximumLength: maxLength)
    }

    static func reindent(_ source: String, indent: String = defaultIndent) -> String {
        reindentIfValid(source, indent: indent) ?? source
    }

    // An edit keeps the stored value's layout: a value stored on one line stays compact, a formatted one takes the
    // editor's lines rather than losing every line break.
    static func staged(_ edited: String, keepingLayoutOf stored: String?) -> String {
        keepsLayout(of: stored) ? edited : normalize(edited)
    }

    // For a caller that already holds `normalize(edited)`.
    static func staged(_ edited: String, compact: String, keepingLayoutOf stored: String?) -> String {
        keepsLayout(of: stored) ? edited : compact
    }

    static func normalize(_ source: String) -> String {
        guard (source as NSString).length <= maxLength else { return source }
        return JsonLayoutWriter.write(source, indent: nil, maximumLength: .max) ?? source
    }

    private static func keepsLayout(of stored: String?) -> Bool {
        guard let stored else { return false }
        return stored.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isNewline)
    }
}

// Writes a document indented or compact in one pass over its UTF-8, with no node tree. It accepts exactly what
// `JsonSyntaxParser` accepts: ASCII whitespace, lax numbers, 512 levels, nothing after the value, strings copied as
// written. A backslash skips one byte here and one scalar there, which agree because a UTF-8 continuation byte is
// never a quote or a backslash.
private struct JsonLayoutWriter {
    private static let maxDepth = 512

    private let source: UnsafeBufferPointer<UInt8>
    private let indent: [UInt8]?
    private let indentLength: Int
    private let maximumLength: Int
    private var index = 0
    private var depth = 0
    private var output: [UInt8] = []
    // UTF-16 units written, the unit `maximumLength` counts in.
    private var written = 0

    static func write(_ source: String, indent: [UInt8]?, maximumLength: Int) -> String? {
        var source = source
        source.makeContiguousUTF8()
        let result = source.utf8.withContiguousStorageIfAvailable { bytes in
            var writer = JsonLayoutWriter(source: bytes, indent: indent, maximumLength: maximumLength)
            return writer.run()
        }
        if let result {
            return result
        }
        return Array(source.utf8).withUnsafeBufferPointer { bytes in
            var writer = JsonLayoutWriter(source: bytes, indent: indent, maximumLength: maximumLength)
            return writer.run()
        }
    }

    private init(source: UnsafeBufferPointer<UInt8>, indent: [UInt8]?, maximumLength: Int) {
        self.source = source
        self.indent = indent
        self.indentLength = indent.map { Self.utf16Length(of: $0[...]) } ?? 0
        self.maximumLength = maximumLength
        output.reserveCapacity(indent == nil ? source.count : source.count + source.count / 2)
    }

    private mutating func run() -> String? {
        skipWhitespace()
        guard writeValue() else { return nil }
        skipWhitespace()
        guard index == source.count, written <= maximumLength else { return nil }
        return String(decoding: output, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }

    private mutating func writeValue() -> Bool {
        guard index < source.count, written <= maximumLength else { return false }
        switch source[index] {
        case UInt8(ascii: "{"): return writeContainer(closing: UInt8(ascii: "}"), hasKeys: true)
        case UInt8(ascii: "["): return writeContainer(closing: UInt8(ascii: "]"), hasKeys: false)
        case UInt8(ascii: "\""): return copyString()
        case UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n"): return copyLiteral()
        default: return copyNumber()
        }
    }

    private mutating func writeContainer(closing: UInt8, hasKeys: Bool) -> Bool {
        guard depth < Self.maxDepth else { return false }
        depth += 1
        defer { depth -= 1 }
        let opening = source[index]
        index += 1
        skipWhitespace()
        if index < source.count, source[index] == closing {
            index += 1
            append(opening)
            append(closing)
            return true
        }
        append(opening)
        var isFirst = true
        while true {
            skipWhitespace()
            if !isFirst {
                append(UInt8(ascii: ","))
            }
            isFirst = false
            appendLineBreak(depth: depth)
            if hasKeys {
                guard index < source.count, source[index] == UInt8(ascii: "\""), copyString() else { return false }
                skipWhitespace()
                guard index < source.count, source[index] == UInt8(ascii: ":") else { return false }
                index += 1
                append(UInt8(ascii: ":"))
                if indent != nil {
                    append(UInt8(ascii: " "))
                }
                skipWhitespace()
            }
            guard writeValue() else { return false }
            skipWhitespace()
            guard index < source.count else { return false }
            if source[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if source[index] == closing {
                index += 1
                appendLineBreak(depth: depth - 1)
                append(closing)
                return true
            }
            return false
        }
    }

    private mutating func copyString() -> Bool {
        let start = index
        index += 1
        while index < source.count {
            let byte = source[index]
            if byte == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            if byte == UInt8(ascii: "\"") {
                index += 1
                copy(from: start)
                return true
            }
            index += 1
        }
        return false
    }

    private mutating func copyNumber() -> Bool {
        let start = index
        if index < source.count, source[index] == UInt8(ascii: "-") { index += 1 }
        guard consumeDigits() else { return false }
        if index < source.count, source[index] == UInt8(ascii: ".") {
            index += 1
            guard consumeDigits() else { return false }
        }
        if index < source.count, source[index] == UInt8(ascii: "e") || source[index] == UInt8(ascii: "E") {
            index += 1
            if index < source.count, source[index] == UInt8(ascii: "+") || source[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard consumeDigits() else { return false }
        }
        copy(from: start)
        return true
    }

    private mutating func consumeDigits() -> Bool {
        guard index < source.count, Self.isDigit(source[index]) else { return false }
        while index < source.count, Self.isDigit(source[index]) { index += 1 }
        return true
    }

    private mutating func copyLiteral() -> Bool {
        let literal: [UInt8]
        switch source[index] {
        case UInt8(ascii: "t"): literal = Self.trueBytes
        case UInt8(ascii: "f"): literal = Self.falseBytes
        default: literal = Self.nullBytes
        }
        guard matches(literal) else { return false }
        let start = index
        index += literal.count
        copy(from: start)
        return true
    }

    private static let trueBytes = Array("true".utf8)
    private static let falseBytes = Array("false".utf8)
    private static let nullBytes = Array("null".utf8)

    private func matches(_ literal: [UInt8]) -> Bool {
        guard index + literal.count <= source.count else { return false }
        for offset in literal.indices where source[index + offset] != literal[offset] {
            return false
        }
        return true
    }

    private mutating func skipWhitespace() {
        while index < source.count {
            switch source[index] {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"): index += 1
            default: return
            }
        }
    }

    private mutating func append(_ byte: UInt8) {
        output.append(byte)
        written += 1
    }

    private mutating func appendLineBreak(depth: Int) {
        guard let indent else { return }
        append(UInt8(ascii: "\n"))
        for _ in 0..<depth {
            output.append(contentsOf: indent)
        }
        written += indentLength * depth
    }

    private mutating func copy(from start: Int) {
        let span = source[start..<index]
        output.append(contentsOf: span)
        written += Self.utf16Length(of: span)
    }

    private static func utf16Length<Bytes: Collection>(of bytes: Bytes) -> Int where Bytes.Element == UInt8 {
        var length = 0
        for byte in bytes where byte & 0xC0 != 0x80 {
            length += byte >= 0xF0 ? 2 : 1
        }
        return length
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
