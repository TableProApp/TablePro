import Foundation

/// A document as JSON text, read strictly and kept in the order it was written.
///
/// Extended JSON is JSON, and every value it can hold is a string, a number, a literal, an array or
/// an object, so reading it needs nothing MongoDB-specific. It is read here rather than by libbson
/// because libbson accepts text that is not one document: it keeps both copies of a repeated field,
/// reads only the first of two documents written one after the other, and turns a top-level array
/// into a document keyed `"0"`, `"1"`. Each of those would write something other than what the
/// user typed without a word.
struct MongoDocumentText: Equatable, Sendable {
    indirect enum Value: Equatable, Sendable {
        case object([Member])
        case array([Value])
        case string(String)
        case number(String)
        case literal(String)
    }

    struct Member: Equatable, Sendable {
        let key: String
        let value: Value
    }

    enum Refusal: Error, Equatable, LocalizedError {
        case empty
        case notAnObject
        case trailingContent
        case malformed(line: Int, column: Int)
        case duplicateField(String)
        case tooDeep

        var errorDescription: String? {
            switch self {
            case .empty:
                return String(localized: "Enter a document.")
            case .notAnObject:
                return String(localized: "A document is one JSON object, written between { and }.")
            case .trailingContent:
                return String(localized: "Enter one document. There is more text after its closing }.")
            case .malformed(let line, let column):
                return String(
                    format: String(localized: "This is not valid JSON at line %1$d, column %2$d."),
                    line,
                    column
                )
            case .duplicateField(let name):
                return String(format: String(localized: "The field \u{201C}%@\u{201D} appears more than once."), name)
            case .tooDeep:
                return String(
                    format: String(localized: "The document is nested more than %d levels deep."),
                    MongoDocumentText.maximumDepth
                )
            }
        }
    }

    /// MongoDB refuses a document nested deeper than this, so nothing deeper is worth reading.
    static let maximumDepth = 100

    let members: [Member]

    init(members: [Member]) {
        self.members = members
    }

    init(parsing text: String) throws {
        var reader = Reader(text)
        reader.skipWhitespace()
        guard !reader.isAtEnd else { throw Refusal.empty }
        guard reader.peek == UInt8(ascii: "{") else { throw Refusal.notAnObject }
        guard case .object(let members) = try reader.readValue(depth: 1) else { throw Refusal.notAnObject }
        reader.skipWhitespace()
        guard reader.isAtEnd else { throw Refusal.trailingContent }
        self.members = members
    }

    /// The document as compact JSON, which is what is sent and what the statement shows.
    var compactText: String {
        Value.object(members).compactText
    }
}

extension MongoDocumentText.Value {
    var compactText: String {
        switch self {
        case .object(let members):
            let body = members.map { "\(MongoDocumentText.quoted($0.key)):\($0.value.compactText)" }
            return "{\(body.joined(separator: ","))}"
        case .array(let elements):
            return "[\(elements.map(\.compactText).joined(separator: ","))]"
        case .string(let value):
            return MongoDocumentText.quoted(value)
        case .number(let text), .literal(let text):
            return text
        }
    }
}

extension MongoDocumentText {
    static func unreadableDocument(_ reason: String) -> String {
        guard !reason.isEmpty else { return String(localized: "MongoDB cannot read this document.") }
        return String(format: String(localized: "MongoDB cannot read this document: %@"), reason)
    }

    static func quoted(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{08}": escaped += "\\b"
            case "\u{0C}": escaped += "\\f"
            default:
                if scalar.value < 0x20 || scalar == "\u{2028}" || scalar == "\u{2029}" {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped + "\""
    }

    /// Reads UTF-8 bytes, because every character JSON gives meaning to is ASCII and a byte index
    /// is the only one that is O(1) on a bridged string.
    fileprivate struct Reader {
        private let bytes: [UInt8]
        private var index = 0

        init(_ text: String) {
            bytes = Array(text.utf8)
        }

        var isAtEnd: Bool { index >= bytes.count }
        var peek: UInt8? { isAtEnd ? nil : bytes[index] }

        mutating func skipWhitespace() {
            while let byte = peek, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
                index += 1
            }
        }

        mutating func readValue(depth: Int) throws -> Value {
            skipWhitespace()
            guard let byte = peek else { throw malformed }
            switch byte {
            case UInt8(ascii: "{"):
                guard depth <= MongoDocumentText.maximumDepth else { throw Refusal.tooDeep }
                return try readObject(depth: depth)
            case UInt8(ascii: "["):
                guard depth <= MongoDocumentText.maximumDepth else { throw Refusal.tooDeep }
                return try readArray(depth: depth)
            case UInt8(ascii: "\""):
                return .string(try readString())
            case UInt8(ascii: "t"):
                return try readLiteral("true")
            case UInt8(ascii: "f"):
                return try readLiteral("false")
            case UInt8(ascii: "n"):
                return try readLiteral("null")
            default:
                return .number(try readNumber())
            }
        }

        private mutating func readObject(depth: Int) throws -> Value {
            index += 1
            var members: [Member] = []
            var seen = Set<Data>()
            skipWhitespace()
            if peek == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard peek == UInt8(ascii: "\"") else { throw malformed }
                let key = try readString()
                guard seen.insert(Data(key.utf8)).inserted else { throw Refusal.duplicateField(key) }
                skipWhitespace()
                guard peek == UInt8(ascii: ":") else { throw malformed }
                index += 1
                members.append(Member(key: key, value: try readValue(depth: depth + 1)))
                skipWhitespace()
                switch peek {
                case UInt8(ascii: ","):
                    index += 1
                case UInt8(ascii: "}"):
                    index += 1
                    return .object(members)
                default:
                    throw malformed
                }
            }
        }

        private mutating func readArray(depth: Int) throws -> Value {
            index += 1
            var elements: [Value] = []
            skipWhitespace()
            if peek == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            }
            while true {
                elements.append(try readValue(depth: depth + 1))
                skipWhitespace()
                switch peek {
                case UInt8(ascii: ","):
                    index += 1
                case UInt8(ascii: "]"):
                    index += 1
                    return .array(elements)
                default:
                    throw malformed
                }
            }
        }

        private mutating func readString() throws -> String {
            index += 1
            var decoded: [UInt8] = []
            while let byte = peek {
                switch byte {
                case UInt8(ascii: "\""):
                    index += 1
                    guard let text = String(bytes: decoded, encoding: .utf8) else { throw malformed }
                    return text
                case UInt8(ascii: "\\"):
                    index += 1
                    decoded.append(contentsOf: String(try readEscape()).utf8)
                case 0x00 ..< 0x20:
                    throw malformed
                default:
                    decoded.append(byte)
                    index += 1
                }
            }
            throw malformed
        }

        private mutating func readEscape() throws -> Unicode.Scalar {
            guard let byte = peek else { throw malformed }
            index += 1
            switch byte {
            case UInt8(ascii: "\""): return "\""
            case UInt8(ascii: "\\"): return "\\"
            case UInt8(ascii: "/"): return "/"
            case UInt8(ascii: "b"): return "\u{08}"
            case UInt8(ascii: "f"): return "\u{0C}"
            case UInt8(ascii: "n"): return "\n"
            case UInt8(ascii: "r"): return "\r"
            case UInt8(ascii: "t"): return "\t"
            case UInt8(ascii: "u"): return try readUnicodeEscape()
            default: throw malformed
            }
        }

        private mutating func readUnicodeEscape() throws -> Unicode.Scalar {
            let high = try readHexQuad()
            if (0xD800 ... 0xDBFF).contains(high) {
                guard peek == UInt8(ascii: "\\") else { throw malformed }
                index += 1
                guard peek == UInt8(ascii: "u") else { throw malformed }
                index += 1
                let low = try readHexQuad()
                guard (0xDC00 ... 0xDFFF).contains(low) else { throw malformed }
                let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else { throw malformed }
                return scalar
            }
            guard let scalar = Unicode.Scalar(high) else { throw malformed }
            return scalar
        }

        private mutating func readHexQuad() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let text = String(bytes: bytes[index ..< index + 4], encoding: .ascii),
                  let value = UInt32(text, radix: 16) else { throw malformed }
            index += 4
            return value
        }

        private mutating func readLiteral(_ literal: String) throws -> Value {
            let expected = Array(literal.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index ..< index + expected.count]) == expected else { throw malformed }
            index += expected.count
            return .literal(literal)
        }

        private mutating func readNumber() throws -> String {
            let start = index
            if peek == UInt8(ascii: "-") { index += 1 }
            guard let first = peek, isDigit(first) else { throw malformed }
            if first == UInt8(ascii: "0") {
                index += 1
            } else {
                skipDigits()
            }
            if peek == UInt8(ascii: ".") {
                index += 1
                guard let byte = peek, isDigit(byte) else { throw malformed }
                skipDigits()
            }
            if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
                index += 1
                if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { index += 1 }
                guard let byte = peek, isDigit(byte) else { throw malformed }
                skipDigits()
            }
            guard let text = String(bytes: bytes[start ..< index], encoding: .ascii) else { throw malformed }
            return text
        }

        private mutating func skipDigits() {
            while let byte = peek, isDigit(byte) { index += 1 }
        }

        private func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        private var malformed: Refusal {
            var line = 1
            var column = 1
            for byte in bytes[0 ..< min(index, bytes.count)] {
                if byte == 0x0A {
                    line += 1
                    column = 1
                } else if byte & 0xC0 != 0x80 {
                    column += 1
                }
            }
            return .malformed(line: line, column: column)
        }
    }
}
