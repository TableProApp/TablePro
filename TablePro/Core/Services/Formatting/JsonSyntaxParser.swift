//
//  JsonSyntaxParser.swift
//  TablePro
//

import Foundation

internal struct JsonObjectMember {
    let key: String
    let value: JsonSyntaxNode
}

internal enum JsonSyntaxNode {
    case object([JsonObjectMember])
    case array([JsonSyntaxNode])
    case string(String)
    case number(String)
    case literal(String)
}

internal enum JsonSyntaxParser {
    static func parse(_ source: String) -> JsonSyntaxNode? {
        var parser = Parser(scalars: Array(source.unicodeScalars))
        parser.skipWhitespace()
        guard let node = parser.parseValue() else { return nil }
        parser.skipWhitespace()
        guard parser.isAtEnd else { return nil }
        return node
    }

    static func decodeStringLiteral(_ raw: String) -> String {
        let scalars = Array(raw.unicodeScalars)
        guard scalars.count >= 2, scalars.first == "\"", scalars.last == "\"" else { return raw }

        var output = String.UnicodeScalarView()
        var index = 1
        let end = scalars.count - 1

        while index < end {
            let scalar = scalars[index]
            if scalar != "\\" {
                output.append(scalar)
                index += 1
                continue
            }
            index += 1
            guard index < end else { break }
            switch scalars[index] {
            case "\"": output.append("\"")
            case "\\": output.append("\\")
            case "/": output.append("/")
            case "b": output.append(Unicode.Scalar(UInt8(8)))
            case "f": output.append(Unicode.Scalar(UInt8(12)))
            case "n": output.append("\n")
            case "r": output.append("\r")
            case "t": output.append("\t")
            case "u":
                if let decoded = Self.decodeUnicodeEscape(scalars, at: &index, end: end) {
                    output.append(decoded)
                }
            default:
                output.append(scalars[index])
            }
            index += 1
        }

        return String(output)
    }

    private static func decodeUnicodeEscape(_ scalars: [Unicode.Scalar], at index: inout Int, end: Int) -> Unicode.Scalar? {
        guard let high = hexValue(scalars, uAt: index, end: end) else { return nil }
        index += 4

        if high >= 0xD800, high <= 0xDBFF,
           index + 2 < end, scalars[index + 1] == "\\", scalars[index + 2] == "u",
           let low = hexValue(scalars, uAt: index + 2, end: end), low >= 0xDC00, low <= 0xDFFF {
            index += 6
            let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
            return Unicode.Scalar(combined)
        }

        return Unicode.Scalar(high)
    }

    private static func hexValue(_ scalars: [Unicode.Scalar], uAt index: Int, end: Int) -> Int? {
        guard index + 4 < end else { return nil }
        var value = 0
        for offset in 1...4 {
            guard let digit = hexDigit(scalars[index + offset]) else { return nil }
            value = value * 16 + digit
        }
        return value
    }

    private static func hexDigit(_ scalar: Unicode.Scalar) -> Int? {
        let value = scalar.value
        if value >= 0x30, value <= 0x39 { return Int(value - 0x30) }
        if value >= 0x61, value <= 0x66 { return Int(value - 0x61 + 10) }
        if value >= 0x41, value <= 0x46 { return Int(value - 0x41 + 10) }
        return nil
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0
        var depth = 0
        let maxDepth = 512

        var isAtEnd: Bool { index >= scalars.count }

        mutating func skipWhitespace() {
            while index < scalars.count {
                switch scalars[index] {
                case " ", "\t", "\n", "\r": index += 1
                default: return
                }
            }
        }

        mutating func parseValue() -> JsonSyntaxNode? {
            guard index < scalars.count else { return nil }
            switch scalars[index] {
            case "{": return parseObject()
            case "[": return parseArray()
            case "\"": return parseString().map { .string($0) }
            case "t", "f", "n": return parseLiteral()
            default: return parseNumber()
            }
        }

        mutating func parseObject() -> JsonSyntaxNode? {
            guard depth < maxDepth else { return nil }
            depth += 1
            defer { depth -= 1 }
            index += 1
            var pairs: [JsonObjectMember] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "}" {
                index += 1
                return .object(pairs)
            }
            while true {
                skipWhitespace()
                guard index < scalars.count, scalars[index] == "\"", let key = parseString() else { return nil }
                skipWhitespace()
                guard index < scalars.count, scalars[index] == ":" else { return nil }
                index += 1
                skipWhitespace()
                guard let value = parseValue() else { return nil }
                pairs.append(JsonObjectMember(key: key, value: value))
                skipWhitespace()
                guard index < scalars.count else { return nil }
                if scalars[index] == "," {
                    index += 1
                    continue
                }
                if scalars[index] == "}" {
                    index += 1
                    return .object(pairs)
                }
                return nil
            }
        }

        mutating func parseArray() -> JsonSyntaxNode? {
            guard depth < maxDepth else { return nil }
            depth += 1
            defer { depth -= 1 }
            index += 1
            var elements: [JsonSyntaxNode] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "]" {
                index += 1
                return .array(elements)
            }
            while true {
                skipWhitespace()
                guard let value = parseValue() else { return nil }
                elements.append(value)
                skipWhitespace()
                guard index < scalars.count else { return nil }
                if scalars[index] == "," {
                    index += 1
                    continue
                }
                if scalars[index] == "]" {
                    index += 1
                    return .array(elements)
                }
                return nil
            }
        }

        mutating func parseString() -> String? {
            let start = index
            index += 1
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "\\" {
                    index += 2
                    continue
                }
                if scalar == "\"" {
                    index += 1
                    return substring(from: start, to: index)
                }
                index += 1
            }
            return nil
        }

        mutating func parseNumber() -> JsonSyntaxNode? {
            let start = index
            if index < scalars.count, scalars[index] == "-" { index += 1 }
            guard consumeDigits() else { return nil }
            if index < scalars.count, scalars[index] == "." {
                index += 1
                guard consumeDigits() else { return nil }
            }
            if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
                index += 1
                if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
                guard consumeDigits() else { return nil }
            }
            return .number(substring(from: start, to: index))
        }

        mutating func consumeDigits() -> Bool {
            guard index < scalars.count, isDigit(scalars[index]) else { return false }
            while index < scalars.count, isDigit(scalars[index]) { index += 1 }
            return true
        }

        mutating func parseLiteral() -> JsonSyntaxNode? {
            for literal in ["true", "false", "null"] where matches(literal) {
                index += literal.unicodeScalars.count
                return .literal(literal)
            }
            return nil
        }

        func matches(_ literal: String) -> Bool {
            let scalarsToMatch = Array(literal.unicodeScalars)
            guard index + scalarsToMatch.count <= scalars.count else { return false }
            for (offset, scalar) in scalarsToMatch.enumerated() where scalars[index + offset] != scalar {
                return false
            }
            return true
        }

        func isDigit(_ scalar: Unicode.Scalar) -> Bool {
            scalar >= "0" && scalar <= "9"
        }

        func substring(from start: Int, to end: Int) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[start..<end])
            return String(view)
        }
    }
}
