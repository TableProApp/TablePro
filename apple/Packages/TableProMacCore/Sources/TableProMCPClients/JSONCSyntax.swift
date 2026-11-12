import Foundation

public enum MCPConfigEditError: Error, Sendable, Equatable {
    case invalidSyntax
    case duplicateKey([String])
    case notAnObject([String])
    case unsupportedShape
    case verificationFailed
}

// The editors splice only at ASCII boundaries of text that arrived as a String, so the bytes stay valid UTF-8.
func utf8Text<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    String(decoding: bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
}

struct JSONCNode {
    enum Content {
        case object([JSONCMember])
        case array([JSONCNode])
        case scalar(JSONValue)
    }

    let content: Content
    let range: Range<Int>

    var members: [JSONCMember]? {
        guard case .object(let members) = content else { return nil }
        return members
    }

    var value: JSONValue {
        switch content {
        case .object(let members): return .object(members.map { (key: $0.key, value: $0.value.value) })
        case .array(let items): return .array(items.map(\.value))
        case .scalar(let scalar): return scalar
        }
    }
}

struct JSONCMember {
    let key: String
    let keyRange: Range<Int>
    let value: JSONCNode
    let commaOffset: Int?
}

// JSON with `//` and `/* */` comments and trailing commas, the dialect VS Code and Zed write. Offsets are UTF-8.
struct JSONCParser {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    private static let maximumDepth = 256

    static func parse(_ bytes: [UInt8]) throws -> JSONCNode? {
        var parser = JSONCParser(bytes: bytes)
        try parser.skipTrivia()
        guard parser.index < bytes.count else { return nil }
        let root = try parser.parseValue()
        try parser.skipTrivia()
        guard parser.index == bytes.count else { throw MCPConfigEditError.invalidSyntax }
        return root
    }

    // JSONSerialization refuses an unpaired surrogate escape, which Node writes; this parser reads it as U+FFFD, so the check does too.
    static func replacingLoneSurrogateEscapes(_ bytes: [UInt8]) -> [UInt8] {
        let backslash = UInt8(ascii: "\\")
        let replacement = [backslash] + Array("uFFFD".utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == backslash, index + 1 < bytes.count else {
                result.append(bytes[index])
                index += 1
                continue
            }
            guard bytes[index + 1] == UInt8(ascii: "u"), let unit = hexUnit(bytes, at: index + 2) else {
                result.append(contentsOf: bytes[index...(index + 1)])
                index += 2
                continue
            }
            if (0xD800..<0xDC00).contains(unit), index + 7 < bytes.count,
               bytes[index + 6] == backslash, bytes[index + 7] == UInt8(ascii: "u"),
               let low = hexUnit(bytes, at: index + 8), (0xDC00..<0xE000).contains(low) {
                result.append(contentsOf: bytes[index..<(index + 12)])
                index += 12
                continue
            }
            if (0xD800..<0xE000).contains(unit) {
                result.append(contentsOf: replacement)
            } else {
                result.append(contentsOf: bytes[index..<(index + 6)])
            }
            index += 6
        }
        return result
    }

    private static func hexUnit(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        return UInt32(utf8Text(bytes[offset..<(offset + 4)]), radix: 16)
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

    private mutating func skipTrivia() throws {
        while let byte = current {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case UInt8(ascii: "/"):
                guard index + 1 < bytes.count else { throw MCPConfigEditError.invalidSyntax }
                if bytes[index + 1] == UInt8(ascii: "/") {
                    while let next = current, next != 0x0A {
                        index += 1
                    }
                } else if bytes[index + 1] == UInt8(ascii: "*") {
                    index += 2
                    while true {
                        guard index + 1 < bytes.count else { throw MCPConfigEditError.invalidSyntax }
                        if bytes[index] == UInt8(ascii: "*"), bytes[index + 1] == UInt8(ascii: "/") {
                            index += 2
                            break
                        }
                        index += 1
                    }
                } else {
                    throw MCPConfigEditError.invalidSyntax
                }
            default:
                return
            }
        }
    }

    private mutating func parseValue() throws -> JSONCNode {
        guard let byte = current else { throw MCPConfigEditError.invalidSyntax }
        let start = index
        switch byte {
        case UInt8(ascii: "{"):
            return try nested { try $0.parseObject() }
        case UInt8(ascii: "["):
            return try nested { try $0.parseArray() }
        case UInt8(ascii: "\""):
            let string = try parseString()
            return JSONCNode(content: .scalar(.string(string)), range: start..<index)
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return JSONCNode(content: .scalar(.bool(true)), range: start..<index)
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return JSONCNode(content: .scalar(.bool(false)), range: start..<index)
        case UInt8(ascii: "n"):
            try expectLiteral("null")
            return JSONCNode(content: .scalar(.null), range: start..<index)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            let number = try parseNumber()
            return JSONCNode(content: .scalar(.number(number)), range: start..<index)
        default:
            throw MCPConfigEditError.invalidSyntax
        }
    }

    private mutating func nested(_ body: (inout JSONCParser) throws -> JSONCNode) throws -> JSONCNode {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maximumDepth else { throw MCPConfigEditError.invalidSyntax }
        return try body(&self)
    }

    private mutating func parseObject() throws -> JSONCNode {
        let start = index
        index += 1
        var members: [JSONCMember] = []
        while true {
            try skipTrivia()
            guard let byte = current else { throw MCPConfigEditError.invalidSyntax }
            if byte == UInt8(ascii: "}") {
                index += 1
                return JSONCNode(content: .object(members), range: start..<index)
            }
            guard byte == UInt8(ascii: "\"") else { throw MCPConfigEditError.invalidSyntax }
            let keyStart = index
            let key = try parseString()
            let keyRange = keyStart..<index
            try skipTrivia()
            guard current == UInt8(ascii: ":") else { throw MCPConfigEditError.invalidSyntax }
            index += 1
            try skipTrivia()
            let value = try parseValue()
            try skipTrivia()
            switch current {
            case UInt8(ascii: ","):
                members.append(JSONCMember(key: key, keyRange: keyRange, value: value, commaOffset: index))
                index += 1
            case UInt8(ascii: "}"):
                members.append(JSONCMember(key: key, keyRange: keyRange, value: value, commaOffset: nil))
                index += 1
                return JSONCNode(content: .object(members), range: start..<index)
            default:
                throw MCPConfigEditError.invalidSyntax
            }
        }
    }

    private mutating func parseArray() throws -> JSONCNode {
        let start = index
        index += 1
        var items: [JSONCNode] = []
        while true {
            try skipTrivia()
            guard let byte = current else { throw MCPConfigEditError.invalidSyntax }
            if byte == UInt8(ascii: "]") {
                index += 1
                return JSONCNode(content: .array(items), range: start..<index)
            }
            items.append(try parseValue())
            try skipTrivia()
            switch current {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                return JSONCNode(content: .array(items), range: start..<index)
            default:
                throw MCPConfigEditError.invalidSyntax
            }
        }
    }

    private mutating func expectLiteral(_ literal: String) throws {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count,
              Array(bytes[index..<(index + literalBytes.count)]) == literalBytes else {
            throw MCPConfigEditError.invalidSyntax
        }
        index += literalBytes.count
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        if current == UInt8(ascii: "-") {
            index += 1
        }
        guard let first = current, Self.isDigit(first) else { throw MCPConfigEditError.invalidSyntax }
        if first == UInt8(ascii: "0") {
            index += 1
        } else {
            skipDigits()
        }
        if current == UInt8(ascii: ".") {
            index += 1
            guard let digit = current, Self.isDigit(digit) else { throw MCPConfigEditError.invalidSyntax }
            skipDigits()
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") {
                index += 1
            }
            guard let digit = current, Self.isDigit(digit) else { throw MCPConfigEditError.invalidSyntax }
            skipDigits()
        }
        let text = utf8Text(bytes[start..<index])
        guard let number = Double(text) else { throw MCPConfigEditError.invalidSyntax }
        return number
    }

    private mutating func skipDigits() {
        while let byte = current, Self.isDigit(byte) {
            index += 1
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while true {
            guard let byte = current else { throw MCPConfigEditError.invalidSyntax }
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return utf8Text(buffer)
            case UInt8(ascii: "\\"):
                index += 1
                try appendEscape(to: &buffer)
            case 0x00..<0x20:
                throw MCPConfigEditError.invalidSyntax
            default:
                buffer.append(byte)
                index += 1
            }
        }
    }

    private mutating func appendEscape(to buffer: inout [UInt8]) throws {
        guard let byte = current else { throw MCPConfigEditError.invalidSyntax }
        index += 1
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): buffer.append(byte)
        case UInt8(ascii: "b"): buffer.append(0x08)
        case UInt8(ascii: "f"): buffer.append(0x0C)
        case UInt8(ascii: "n"): buffer.append(0x0A)
        case UInt8(ascii: "r"): buffer.append(0x0D)
        case UInt8(ascii: "t"): buffer.append(0x09)
        case UInt8(ascii: "u"):
            var scalarValue = try parseHex4()
            if (0xD800..<0xDC00).contains(scalarValue),
               index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                let saved = index
                index += 2
                let low = try parseHex4()
                if (0xDC00..<0xE000).contains(low) {
                    scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                } else {
                    index = saved
                }
            }
            let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
            buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
        default:
            throw MCPConfigEditError.invalidSyntax
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count,
              let value = UInt32(utf8Text(bytes[index..<(index + 4)]), radix: 16) else {
            throw MCPConfigEditError.invalidSyntax
        }
        index += 4
        return value
    }
}
