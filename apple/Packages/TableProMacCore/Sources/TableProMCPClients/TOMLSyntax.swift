import Foundation

struct TOMLStatement {
    enum Kind {
        case table(keys: [String], isArray: Bool)
        case keyValue(keys: [String], value: JSONValue)
    }

    let kind: Kind
    let lineStart: Int
    // Past the line break that ends the statement, or the end of the text.
    let lineEnd: Int
}

// Enough of TOML 1.0 to find every statement's keys and line range and to read the values a server table holds.
// Dates and times come back as their source text.
struct TOMLParser {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0

    static func parse(_ bytes: [UInt8]) throws -> [TOMLStatement] {
        var parser = TOMLParser(bytes: bytes)
        return try parser.statements()
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            index = 3
        }
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func byte(at offset: Int) -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    private mutating func statements() throws -> [TOMLStatement] {
        var result: [TOMLStatement] = []
        while true {
            skipBlankLinesAndComments()
            guard let byte = current else { return result }
            let start = index
            var lineStart = start
            while lineStart > 0, bytes[lineStart - 1] != 0x0A {
                lineStart -= 1
            }
            let kind: TOMLStatement.Kind
            if byte == UInt8(ascii: "[") {
                let isArray = self.byte(at: index + 1) == UInt8(ascii: "[")
                index += isArray ? 2 : 1
                skipSpaces()
                let keys = try parseKey()
                try expect("]")
                if isArray {
                    try expect("]")
                }
                kind = .table(keys: keys, isArray: isArray)
            } else {
                let keys = try parseKey()
                try expect("=")
                skipSpaces()
                kind = .keyValue(keys: keys, value: try parseValue())
            }
            skipSpaces()
            skipComment()
            switch current {
            case nil:
                break
            case 0x0A:
                index += 1
            case 0x0D where self.byte(at: index + 1) == 0x0A:
                index += 2
            default:
                throw MCPConfigEditError.invalidSyntax
            }
            result.append(TOMLStatement(kind: kind, lineStart: lineStart, lineEnd: index))
        }
    }

    private mutating func skipSpaces() {
        while let byte = current, byte == 0x20 || byte == 0x09 {
            index += 1
        }
    }

    private mutating func skipComment() {
        guard current == UInt8(ascii: "#") else { return }
        while let byte = current, byte != 0x0A {
            index += 1
        }
        if index > 0, bytes[index - 1] == 0x0D {
            index -= 1
        }
    }

    private mutating func skipBlankLinesAndComments() {
        while let byte = current {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case UInt8(ascii: "#"):
                while let next = current, next != 0x0A {
                    index += 1
                }
            default:
                return
            }
        }
    }

    private mutating func expect(_ character: Character) throws {
        skipSpaces()
        guard let ascii = character.asciiValue, current == ascii else { throw MCPConfigEditError.invalidSyntax }
        index += 1
    }

    private mutating func parseKey() throws -> [String] {
        var keys: [String] = []
        while true {
            skipSpaces()
            guard let byte = current else { throw MCPConfigEditError.invalidSyntax }
            switch byte {
            case UInt8(ascii: "\""):
                keys.append(try parseBasicString())
            case UInt8(ascii: "'"):
                keys.append(try parseLiteralString())
            default:
                let start = index
                while let next = current, Self.isBareKeyByte(next) {
                    index += 1
                }
                guard index > start else { throw MCPConfigEditError.invalidSyntax }
                keys.append(utf8Text(bytes[start..<index]))
            }
            skipSpaces()
            guard current == UInt8(ascii: ".") else { return keys }
            index += 1
        }
    }

    static func isBareKeyByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard let byte = current else { throw MCPConfigEditError.invalidSyntax }
        switch byte {
        case UInt8(ascii: "\""):
            if self.byte(at: index + 1) == UInt8(ascii: "\""), self.byte(at: index + 2) == UInt8(ascii: "\"") {
                return .string(try parseMultilineBasicString())
            }
            return .string(try parseBasicString())
        case UInt8(ascii: "'"):
            if self.byte(at: index + 1) == UInt8(ascii: "'"), self.byte(at: index + 2) == UInt8(ascii: "'") {
                return .string(try parseMultilineLiteralString())
            }
            return .string(try parseLiteralString())
        case UInt8(ascii: "["):
            return try nested { try $0.parseArray() }
        case UInt8(ascii: "{"):
            return try nested { try $0.parseInlineTable() }
        default:
            return try parseBareValue()
        }
    }

    private mutating func nested(_ body: (inout TOMLParser) throws -> JSONValue) throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 128 else { throw MCPConfigEditError.invalidSyntax }
        return try body(&self)
    }

    private mutating func skipValueTrivia() {
        while let byte = current {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case UInt8(ascii: "#"):
                while let next = current, next != 0x0A {
                    index += 1
                }
            default:
                return
            }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        index += 1
        var items: [JSONValue] = []
        while true {
            skipValueTrivia()
            guard let byte = current else { throw MCPConfigEditError.invalidSyntax }
            if byte == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            items.append(try parseValue())
            skipValueTrivia()
            switch current {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                return .array(items)
            default:
                throw MCPConfigEditError.invalidSyntax
            }
        }
    }

    private mutating func parseInlineTable() throws -> JSONValue {
        index += 1
        var members: [(key: String, value: JSONValue)] = []
        while true {
            skipValueTrivia()
            guard let byte = current else { throw MCPConfigEditError.invalidSyntax }
            if byte == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            let keys = try parseKey()
            try expect("=")
            skipSpaces()
            let value = try parseValue()
            try TOMLTree.insert(value, at: keys, into: &members)
            skipValueTrivia()
            switch current {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "}"):
                index += 1
                return .object(members)
            default:
                throw MCPConfigEditError.invalidSyntax
            }
        }
    }

    private mutating func parseBareValue() throws -> JSONValue {
        let start = index
        while let byte = current, !Self.endsBareValue(byte) {
            index += 1
        }
        // A local date and a time may be separated by one space.
        if index - start == 10, current == 0x20, let next = self.byte(at: index + 1), Self.isDigit(next),
           bytes[start + 4] == UInt8(ascii: "-") {
            index += 1
            while let byte = current, !Self.endsBareValue(byte) {
                index += 1
            }
        }
        let text = utf8Text(bytes[start..<index])
        switch text {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "inf", "+inf": return .number(.infinity)
        case "-inf": return .number(-.infinity)
        case "nan", "+nan", "-nan": return .number(.nan)
        default: break
        }
        if let number = Self.number(text) {
            return .number(number)
        }
        guard let first = text.utf8.first, Self.isDigit(first), text.contains(where: { $0 == "-" || $0 == ":" }) else {
            throw MCPConfigEditError.invalidSyntax
        }
        return .string(text)
    }

    private static func number(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "_", with: "")
        guard !cleaned.isEmpty, !text.hasPrefix("_"), !text.hasSuffix("_"), !text.contains("__") else { return nil }
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where cleaned.hasPrefix(prefix) {
            return Int64(cleaned.dropFirst(2), radix: radix).map(Double.init)
        }
        let allowed = Set("0123456789+-.eE")
        guard cleaned.allSatisfy({ allowed.contains($0) }), cleaned.contains(where: \.isNumber) else { return nil }
        return Double(cleaned)
    }

    private static func endsBareValue(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"), UInt8(ascii: "#"):
            return true
        default:
            return false
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private mutating func parseBasicString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while true {
            guard let byte = current, byte != 0x0A else { throw MCPConfigEditError.invalidSyntax }
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return utf8Text(buffer)
            case UInt8(ascii: "\\"):
                index += 1
                try appendEscape(to: &buffer)
            default:
                buffer.append(byte)
                index += 1
            }
        }
    }

    private mutating func parseMultilineBasicString() throws -> String {
        index += 3
        skipLeadingNewline()
        var buffer: [UInt8] = []
        while true {
            guard let byte = current else { throw MCPConfigEditError.invalidSyntax }
            if byte == UInt8(ascii: "\""), closesMultiline(UInt8(ascii: "\"")) {
                return finishMultiline(buffer, quote: UInt8(ascii: "\""))
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                if let whitespaceEnd = lineEndingBackslashEnd() {
                    index = whitespaceEnd
                } else {
                    try appendEscape(to: &buffer)
                }
                continue
            }
            buffer.append(byte)
            index += 1
        }
    }

    private mutating func parseLiteralString() throws -> String {
        index += 1
        let start = index
        while let byte = current, byte != UInt8(ascii: "'") {
            guard byte != 0x0A else { throw MCPConfigEditError.invalidSyntax }
            index += 1
        }
        guard current != nil else { throw MCPConfigEditError.invalidSyntax }
        let text = utf8Text(bytes[start..<index])
        index += 1
        return text
    }

    private mutating func parseMultilineLiteralString() throws -> String {
        index += 3
        skipLeadingNewline()
        var buffer: [UInt8] = []
        while true {
            guard let byte = current else { throw MCPConfigEditError.invalidSyntax }
            if byte == UInt8(ascii: "'"), closesMultiline(UInt8(ascii: "'")) {
                return finishMultiline(buffer, quote: UInt8(ascii: "'"))
            }
            buffer.append(byte)
            index += 1
        }
    }

    private mutating func skipLeadingNewline() {
        if current == 0x0A {
            index += 1
        } else if current == 0x0D, byte(at: index + 1) == 0x0A {
            index += 2
        }
    }

    private func closesMultiline(_ quote: UInt8) -> Bool {
        byte(at: index + 1) == quote && byte(at: index + 2) == quote
    }

    // Up to two quotes may sit right before the closing three.
    private mutating func finishMultiline(_ buffer: [UInt8], quote: UInt8) -> String {
        var run = 0
        while byte(at: index + run) == quote {
            run += 1
        }
        let extra = min(max(run - 3, 0), 2)
        index += extra + 3
        return utf8Text(buffer + Array(repeating: quote, count: extra))
    }

    private func lineEndingBackslashEnd() -> Int? {
        var offset = index
        while let next = byte(at: offset), next == 0x20 || next == 0x09 {
            offset += 1
        }
        guard byte(at: offset) == 0x0A || (byte(at: offset) == 0x0D && byte(at: offset + 1) == 0x0A) else { return nil }
        while let next = byte(at: offset), next == 0x20 || next == 0x09 || next == 0x0A || next == 0x0D {
            offset += 1
        }
        return offset
    }

    private mutating func appendEscape(to buffer: inout [UInt8]) throws {
        guard let byte = current else { throw MCPConfigEditError.invalidSyntax }
        index += 1
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"): buffer.append(byte)
        case UInt8(ascii: "b"): buffer.append(0x08)
        case UInt8(ascii: "t"): buffer.append(0x09)
        case UInt8(ascii: "n"): buffer.append(0x0A)
        case UInt8(ascii: "f"): buffer.append(0x0C)
        case UInt8(ascii: "r"): buffer.append(0x0D)
        case UInt8(ascii: "e"): buffer.append(0x1B)
        case UInt8(ascii: "x"): try appendScalar(hexDigits: 2, to: &buffer)
        case UInt8(ascii: "u"): try appendScalar(hexDigits: 4, to: &buffer)
        case UInt8(ascii: "U"): try appendScalar(hexDigits: 8, to: &buffer)
        default: throw MCPConfigEditError.invalidSyntax
        }
    }

    private mutating func appendScalar(hexDigits: Int, to buffer: inout [UInt8]) throws {
        guard index + hexDigits <= bytes.count,
              let value = UInt32(utf8Text(bytes[index..<(index + hexDigits)]), radix: 16),
              let scalar = Unicode.Scalar(value) else {
            throw MCPConfigEditError.invalidSyntax
        }
        index += hexDigits
        buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
    }
}

enum TOMLTree {
    static func insert(_ value: JSONValue, at keys: [String], into members: inout [(key: String, value: JSONValue)]) throws {
        guard let key = keys.first else { throw MCPConfigEditError.invalidSyntax }
        let position = members.firstIndex { $0.key == key }
        guard keys.count > 1 else {
            guard position == nil else { throw MCPConfigEditError.duplicateKey(keys) }
            members.append((key: key, value: value))
            return
        }
        var children: [(key: String, value: JSONValue)] = []
        if let position {
            guard case .object(let existing) = members[position].value else { throw MCPConfigEditError.invalidSyntax }
            children = existing
        }
        try insert(value, at: Array(keys.dropFirst()), into: &children)
        if let position {
            members[position].value = .object(children)
        } else {
            members.append((key: key, value: .object(children)))
        }
    }
}
