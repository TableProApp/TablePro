import Foundation
import TableProNumberFormatting

/// A JSON tree that keeps every number as the text it was written with.
///
/// A DynamoDB Number carries 38 significant digits, which no `Double` holds, so every JSON this
/// driver reads or writes goes through here rather than `JSONSerialization`: the text of a map cell,
/// a request the editor sends, and every response.
enum DynamoDBJSON: Sendable, Equatable {
    case object([String: DynamoDBJSON])
    case array([DynamoDBJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    subscript(key: String) -> DynamoDBJSON? {
        guard case .object(let entries) = self else { return nil }
        return entries[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberText: String? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        numberText.flatMap { Int($0) }
    }

    var doubleValue: Double? {
        numberText.flatMap { Double($0) }
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [DynamoDBJSON]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    var objectValue: [String: DynamoDBJSON]? {
        guard case .object(let entries) = self else { return nil }
        return entries
    }

    func serialized(pretty: Bool = false) -> String {
        NumberText.json(from: foundationValue, sortedKeys: true, prettyPrinted: pretty) ?? "null"
    }

    var serializedData: Data {
        Data(serialized().utf8)
    }

    private var foundationValue: Any {
        switch self {
        case .object(let entries):
            return entries.mapValues(\.foundationValue)
        case .array(let items):
            return items.map(\.foundationValue)
        case .string(let value):
            return value
        case .number(let text):
            return NumberText.RawNumber(text) ?? NSNull()
        case .bool(let value):
            return NSNumber(value: value)
        case .null:
            return NSNull()
        }
    }
}

extension DynamoDBJSON {
    enum ParseError: Error, LocalizedError, Equatable {
        case unexpected(offset: Int)
        case duplicateKey(String)
        case tooDeep
        case trailingText(offset: Int)

        var errorDescription: String? {
            switch self {
            case .unexpected(let offset):
                return String(format: String(localized: "Not valid JSON at character %d"), offset + 1)
            case .duplicateKey(let key):
                return String(format: String(localized: "The key \"%@\" appears twice in one JSON object"), key)
            case .tooDeep:
                return String(localized: "The JSON is nested more deeply than DynamoDB allows")
            case .trailingText(let offset):
                return String(format: String(localized: "Unexpected text after the JSON at character %d"), offset + 1)
            }
        }
    }

    static func parse(_ text: String) throws -> DynamoDBJSON {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        return try parser.parseDocument()
    }

    static func parse(_ data: Data) throws -> DynamoDBJSON {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ParseError.unexpected(offset: 0)
        }
        return try parse(text)
    }

    /// Parses the JSON value at the start of `text` and reports where it ended, for statements
    /// that carry clauses after their JSON body.
    static func parsePrefix(_ text: String) throws -> (value: DynamoDBJSON, remainder: String) {
        let scalars = Array(text.unicodeScalars)
        var parser = Parser(scalars: scalars)
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        var remainder = String.UnicodeScalarView()
        remainder.append(contentsOf: scalars[parser.position...])
        return (value, String(remainder))
    }

    private struct Parser {
        static let maximumDepth = 128

        let scalars: [Unicode.Scalar]
        var position = 0

        init(scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        mutating func parseDocument() throws -> DynamoDBJSON {
            skipWhitespace()
            let value = try parseValue(depth: 0)
            skipWhitespace()
            guard position == scalars.count else { throw ParseError.trailingText(offset: position) }
            return value
        }

        mutating func skipWhitespace() {
            while position < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[position]) {
                position += 1
            }
        }

        mutating func parseValue(depth: Int) throws -> DynamoDBJSON {
            guard depth <= Self.maximumDepth else { throw ParseError.tooDeep }
            guard position < scalars.count else { throw ParseError.unexpected(offset: position) }
            switch scalars[position] {
            case "{":
                return try parseObject(depth: depth)
            case "[":
                return try parseArray(depth: depth)
            case "\"":
                return .string(try parseString())
            case "t":
                try expectLiteral("true")
                return .bool(true)
            case "f":
                try expectLiteral("false")
                return .bool(false)
            case "n":
                try expectLiteral("null")
                return .null
            default:
                return .number(try parseNumber())
            }
        }

        private mutating func parseObject(depth: Int) throws -> DynamoDBJSON {
            position += 1
            var entries: [String: DynamoDBJSON] = [:]
            skipWhitespace()
            if position < scalars.count, scalars[position] == "}" {
                position += 1
                return .object(entries)
            }
            while true {
                skipWhitespace()
                guard position < scalars.count, scalars[position] == "\"" else {
                    throw ParseError.unexpected(offset: position)
                }
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                guard entries[key] == nil else { throw ParseError.duplicateKey(key) }
                entries[key] = value
                skipWhitespace()
                guard position < scalars.count else { throw ParseError.unexpected(offset: position) }
                if scalars[position] == "," {
                    position += 1
                    continue
                }
                try expect("}")
                return .object(entries)
            }
        }

        private mutating func parseArray(depth: Int) throws -> DynamoDBJSON {
            position += 1
            var items: [DynamoDBJSON] = []
            skipWhitespace()
            if position < scalars.count, scalars[position] == "]" {
                position += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard position < scalars.count else { throw ParseError.unexpected(offset: position) }
                if scalars[position] == "," {
                    position += 1
                    continue
                }
                try expect("]")
                return .array(items)
            }
        }

        private mutating func parseString() throws -> String {
            position += 1
            var result = String.UnicodeScalarView()
            while position < scalars.count {
                let scalar = scalars[position]
                position += 1
                switch scalar {
                case "\"":
                    return String(result)
                case "\\":
                    result.append(try parseEscape())
                default:
                    guard scalar.value >= 0x20 else { throw ParseError.unexpected(offset: position - 1) }
                    result.append(scalar)
                }
            }
            throw ParseError.unexpected(offset: position)
        }

        private mutating func parseEscape() throws -> Unicode.Scalar {
            guard position < scalars.count else { throw ParseError.unexpected(offset: position) }
            let marker = scalars[position]
            position += 1
            switch marker {
            case "\"": return "\""
            case "\\": return "\\"
            case "/": return "/"
            case "b": return "\u{08}"
            case "f": return "\u{0C}"
            case "n": return "\n"
            case "r": return "\r"
            case "t": return "\t"
            case "u":
                let high = try parseHexQuad()
                guard (0xD800...0xDBFF).contains(high) else {
                    guard let scalar = Unicode.Scalar(high) else { throw ParseError.unexpected(offset: position) }
                    return scalar
                }
                guard position + 1 < scalars.count, scalars[position] == "\\", scalars[position + 1] == "u" else {
                    throw ParseError.unexpected(offset: position)
                }
                position += 2
                let low = try parseHexQuad()
                guard (0xDC00...0xDFFF).contains(low) else { throw ParseError.unexpected(offset: position) }
                let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else { throw ParseError.unexpected(offset: position) }
                return scalar
            default:
                throw ParseError.unexpected(offset: position - 1)
            }
        }

        private mutating func parseHexQuad() throws -> UInt32 {
            guard position + 4 <= scalars.count else { throw ParseError.unexpected(offset: position) }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = UInt32(String(scalars[position]), radix: 16) else {
                    throw ParseError.unexpected(offset: position)
                }
                value = value * 16 + digit
                position += 1
            }
            return value
        }

        private mutating func parseNumber() throws -> String {
            let start = position
            while position < scalars.count, Self.numberScalars.contains(scalars[position]) {
                position += 1
            }
            var text = String.UnicodeScalarView()
            text.append(contentsOf: scalars[start..<position])
            let literal = String(text)
            guard NumberText.isJSONNumberLiteral(literal) else { throw ParseError.unexpected(offset: start) }
            return literal
        }

        private static let numberScalars: Set<Unicode.Scalar> = [
            "-", "+", ".", "e", "E", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"
        ]

        private mutating func expect(_ scalar: Unicode.Scalar) throws {
            guard position < scalars.count, scalars[position] == scalar else {
                throw ParseError.unexpected(offset: position)
            }
            position += 1
        }

        private mutating func expectLiteral(_ literal: String) throws {
            for scalar in literal.unicodeScalars {
                try expect(scalar)
            }
        }
    }
}
