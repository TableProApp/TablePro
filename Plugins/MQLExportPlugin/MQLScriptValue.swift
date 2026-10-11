//
//  MQLScriptValue.swift
//  MQLExportPlugin
//

import Foundation
import TableProJavaScriptText
import TableProNumberFormatting

/// A literal value read out of shell text, which the export writes again by its own rules rather
/// than copying the text it came from.
indirect enum MQLScriptValue: Equatable {
    case string(String)
    case number(String)
    case boolean(Bool)
    case null
    case nonFinite(String)
    case array([MQLScriptValue])
    case object([MQLScriptMember])
    case constructor(String, [MQLScriptValue])

    /// The shell constructors a collection definition writes a typed value with.
    static let constructors: Set<String> = [
        "BinData", "Code", "Double", "ISODate", "MaxKey", "MinKey", "NumberDecimal", "NumberLong", "ObjectId",
        "Timestamp"
    ]

    var compactText: String {
        switch self {
        case .string(let value):
            return JavaScriptText.stringLiteral(value)
        case .number(let text), .nonFinite(let text):
            return text
        case .boolean(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .array(let elements):
            return "[\(elements.map(\.compactText).joined(separator: ", "))]"
        case .object(let members):
            let pairs = members.map { "\(JavaScriptText.stringLiteral($0.key)): \($0.value.compactText)" }
            return "{\(pairs.joined(separator: ", "))}"
        case .constructor(let name, let arguments):
            return "\(name)(\(arguments.map(\.compactText).joined(separator: ", ")))"
        }
    }

    /// One member or element per line, `depth` levels in, with a constructor call kept on one line.
    func indentedText(depth: Int) -> String {
        let inner = String(repeating: "  ", count: depth + 1)
        let outer = String(repeating: "  ", count: depth)
        switch self {
        case .array(let elements) where !elements.isEmpty:
            let lines = elements.map { inner + $0.indentedText(depth: depth + 1) }
            return "[\n\(lines.joined(separator: ",\n"))\n\(outer)]"
        case .object(let members) where !members.isEmpty:
            let lines = members.map {
                "\(inner)\(JavaScriptText.stringLiteral($0.key)): \($0.value.indentedText(depth: depth + 1))"
            }
            return "{\n\(lines.joined(separator: ",\n"))\n\(outer)}"
        default:
            return compactText
        }
    }
}

struct MQLScriptMember: Equatable {
    let key: String
    let value: MQLScriptValue
}

/// Reads statements and literal values from a token run, one construct at a time.
///
/// Each read either returns what it matched and moves past it, or returns nil. A caller that needs
/// to try one shape and then another works on a copy, which is cheap because the tokens are shared.
struct MQLScriptReader {
    private let tokens: [MQLScriptToken]
    private(set) var index: Int

    init(tokens: [MQLScriptToken], index: Int = 0) {
        self.tokens = tokens
        self.index = index
    }

    var current: MQLScriptToken? {
        index < tokens.count ? tokens[index] : nil
    }

    mutating func advance() {
        index += 1
    }

    mutating func consume(_ punctuator: Unicode.Scalar) -> Bool {
        guard current == .punctuator(punctuator) else { return false }
        index += 1
        return true
    }

    mutating func identifier() -> String? {
        guard case .identifier(let name)? = current else { return nil }
        index += 1
        return name
    }

    mutating func string() -> String? {
        guard case .string(let value)? = current else { return nil }
        index += 1
        return value
    }

    mutating func value() -> MQLScriptValue? {
        guard let token = current else { return nil }
        index += 1
        switch token {
        case .string(let text):
            return .string(text)
        case .number(let text):
            return NumberText.isJSONNumberLiteral(text) ? .number(text) : nil
        case .punctuator("{"):
            return members().map(MQLScriptValue.object)
        case .punctuator("["):
            return elements(closedBy: "]").map(MQLScriptValue.array)
        case .punctuator("-"):
            return negated()
        case .identifier(let name):
            return named(name)
        default:
            return nil
        }
    }

    private mutating func negated() -> MQLScriptValue? {
        switch current {
        case .number(let text)?:
            index += 1
            let negative = "-" + text
            return NumberText.isJSONNumberLiteral(negative) ? .number(negative) : nil
        case .identifier("Infinity")?:
            index += 1
            return .nonFinite("-Infinity")
        default:
            return nil
        }
    }

    private mutating func named(_ name: String) -> MQLScriptValue? {
        switch name {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        case "null": return .null
        case "Infinity", "NaN": return .nonFinite(name)
        default:
            guard MQLScriptValue.constructors.contains(name), consume("(") else { return nil }
            return elements(closedBy: ")").map { .constructor(name, $0) }
        }
    }

    private mutating func members() -> [MQLScriptMember]? {
        var members: [MQLScriptMember] = []
        while !consume("}") {
            guard let key = string() ?? identifier(), consume(":"), let value = value() else { return nil }
            members.append(MQLScriptMember(key: key, value: value))
            guard consume(",") || current == .punctuator("}") else { return nil }
        }
        return members
    }

    private mutating func elements(closedBy closer: Unicode.Scalar) -> [MQLScriptValue]? {
        var elements: [MQLScriptValue] = []
        while !consume(closer) {
            guard let element = value() else { return nil }
            elements.append(element)
            guard consume(",") || current == .punctuator(closer) else { return nil }
        }
        return elements
    }
}
