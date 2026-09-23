//
//  DynamoDBRequestJSON.swift
//  TablePro
//

import Foundation

/// The body of a DynamoDB request as the classifier reads it.
///
/// It accepts every document the driver's own strict parser accepts, and a few it would refuse, so a request the
/// driver runs is never read as unparseable. An object keeps every member in order, repeated keys included, and key
/// lookups ignore case, so nothing a request spells can hide from a rule that looks for it.
enum DynamoDBRequestJSON: Sendable, Equatable {
    case object([Member])
    case array([DynamoDBRequestJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    struct Member: Sendable, Equatable {
        let key: String
        let value: DynamoDBRequestJSON
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    var elements: [DynamoDBRequestJSON] {
        guard case .array(let items) = self else { return [] }
        return items
    }

    var memberValues: [DynamoDBRequestJSON] {
        guard case .object(let members) = self else { return [] }
        return members.map(\.value)
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    func values(forKey key: String) -> [DynamoDBRequestJSON] {
        guard case .object(let members) = self else { return [] }
        return members.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }.map(\.value)
    }

    func hasMember(_ key: String) -> Bool {
        !values(forKey: key).isEmpty
    }

    /// Parses the JSON value at the start of `text`, and the text after it.
    static func parsePrefix(_ text: Substring) -> (value: DynamoDBRequestJSON, remainder: String)? {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        guard let value = parser.parseValue(depth: 0) else { return nil }
        var remainder = String.UnicodeScalarView()
        remainder.append(contentsOf: parser.scalars[parser.position...])
        return (value, String(remainder))
    }
}

private extension DynamoDBRequestJSON {
    struct Parser {
        static let maximumDepth = 128
        static let numberScalars: Set<Unicode.Scalar> = [
            "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "-", "+", ".", "e", "E"
        ]
        static let replacement: Unicode.Scalar = "\u{FFFD}"

        let scalars: [Unicode.Scalar]
        var position = 0

        mutating func parseValue(depth: Int) -> DynamoDBRequestJSON? {
            guard depth <= Self.maximumDepth else { return nil }
            skipWhitespace()
            guard position < scalars.count else { return nil }
            switch scalars[position] {
            case "{":
                return parseObject(depth: depth)
            case "[":
                return parseArray(depth: depth)
            case "\"":
                return parseString().map(DynamoDBRequestJSON.string)
            case "t":
                return parseLiteral("true", as: .bool(true))
            case "f":
                return parseLiteral("false", as: .bool(false))
            case "n":
                return parseLiteral("null", as: .null)
            default:
                return parseNumber()
            }
        }

        mutating func skipWhitespace() {
            while position < scalars.count, scalars[position].properties.isWhitespace {
                position += 1
            }
        }

        private mutating func parseObject(depth: Int) -> DynamoDBRequestJSON? {
            position += 1
            var members: [Member] = []
            skipWhitespace()
            if position < scalars.count, scalars[position] == "}" {
                position += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard position < scalars.count, scalars[position] == "\"", let key = parseString() else { return nil }
                skipWhitespace()
                guard consume(":"), let value = parseValue(depth: depth + 1) else { return nil }
                members.append(Member(key: key, value: value))
                skipWhitespace()
                if consume(",") { continue }
                guard consume("}") else { return nil }
                return .object(members)
            }
        }

        private mutating func parseArray(depth: Int) -> DynamoDBRequestJSON? {
            position += 1
            var items: [DynamoDBRequestJSON] = []
            skipWhitespace()
            if consume("]") { return .array(items) }
            while true {
                guard let item = parseValue(depth: depth + 1) else { return nil }
                items.append(item)
                skipWhitespace()
                if consume(",") { continue }
                guard consume("]") else { return nil }
                return .array(items)
            }
        }

        private mutating func parseString() -> String? {
            position += 1
            var result = String.UnicodeScalarView()
            while position < scalars.count {
                let scalar = scalars[position]
                position += 1
                if scalar == "\"" { return String(result) }
                guard scalar == "\\" else {
                    result.append(scalar)
                    continue
                }
                guard let escaped = parseEscape() else { return nil }
                result.append(escaped)
            }
            return nil
        }

        private mutating func parseEscape() -> Unicode.Scalar? {
            guard position < scalars.count else { return nil }
            let marker = scalars[position]
            position += 1
            switch marker {
            case "b": return "\u{08}"
            case "f": return "\u{0C}"
            case "n": return "\n"
            case "r": return "\r"
            case "t": return "\t"
            case "u": return parseUnicodeEscape()
            default: return marker
            }
        }

        private mutating func parseUnicodeEscape() -> Unicode.Scalar? {
            guard let high = parseHexQuad() else { return nil }
            guard (0xD800...0xDBFF).contains(high) else {
                return Unicode.Scalar(high) ?? Self.replacement
            }
            guard position + 1 < scalars.count, scalars[position] == "\\", scalars[position + 1] == "u" else {
                return Self.replacement
            }
            position += 2
            guard let low = parseHexQuad() else { return nil }
            guard (0xDC00...0xDFFF).contains(low) else { return Self.replacement }
            return Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)) ?? Self.replacement
        }

        private mutating func parseHexQuad() -> UInt32? {
            guard position + 4 <= scalars.count else { return nil }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = UInt32(String(scalars[position]), radix: 16) else { return nil }
                value = value * 16 + digit
                position += 1
            }
            return value
        }

        private mutating func parseNumber() -> DynamoDBRequestJSON? {
            let start = position
            while position < scalars.count, Self.numberScalars.contains(scalars[position]) {
                position += 1
            }
            guard position > start else { return nil }
            var text = String.UnicodeScalarView()
            text.append(contentsOf: scalars[start..<position])
            return .number(String(text))
        }

        private mutating func parseLiteral(_ literal: String, as value: DynamoDBRequestJSON) -> DynamoDBRequestJSON? {
            let expected = Array(literal.unicodeScalars)
            guard position + expected.count <= scalars.count,
                  Array(scalars[position..<(position + expected.count)]) == expected
            else { return nil }
            position += expected.count
            return value
        }

        private mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
            guard position < scalars.count, scalars[position] == scalar else { return false }
            position += 1
            return true
        }
    }
}
