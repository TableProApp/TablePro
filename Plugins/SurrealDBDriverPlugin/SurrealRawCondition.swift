//
//  SurrealRawCondition.swift
//  SurrealDBDriverPlugin
//

import Foundation

internal enum SurrealRawCondition {
    static func parenthesized(_ text: String) throws(SurrealFilterRefusal) -> String? {
        let condition = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !condition.isEmpty else { return nil }
        guard onlyReads(Array(condition.unicodeScalars)) else { throw .rawConditionNotReadOnly }
        return "(" + condition + ")"
    }

    private static let writingKeywords: Set<String> = [
        "ACCESS", "ALTER", "CREATE", "DEFINE", "DELETE", "INSERT", "KILL", "LIVE", "OPTION",
        "REBUILD", "RELATE", "REMOVE", "UPDATE", "UPSERT", "USE"
    ]

    private static let writingFunctionNamespaces: Set<String> = ["api", "file", "fn", "http", "sequence"]

    private static func onlyReads(_ scalars: [Unicode.Scalar]) -> Bool {
        var index = 0
        var depth = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if let closing = closingDelimiter(of: scalar) {
                guard let end = endOfQuoted(scalars, from: index + 1, closing: closing) else { return false }
                index = end + 1
                continue
            }
            if isWordScalar(scalar) {
                let end = endOfWord(scalars, from: index)
                guard wordOnlyReads(scalars, start: index, end: end) else { return false }
                index = end
                continue
            }
            guard !startsStatementOrComment(scalars, at: index) else { return false }
            if scalar == "(" {
                depth += 1
            } else if scalar == ")" {
                depth -= 1
                guard depth >= 0 else { return false }
            }
            index += 1
        }
        return depth == 0
    }

    private static func closingDelimiter(of scalar: Unicode.Scalar) -> Unicode.Scalar? {
        switch scalar {
        case "'", "\"", "`":
            return scalar
        case "\u{27E8}":
            return "\u{27E9}"
        default:
            return nil
        }
    }

    private static func endOfQuoted(_ scalars: [Unicode.Scalar], from start: Int, closing: Unicode.Scalar) -> Int? {
        var index = start
        while index < scalars.count {
            if scalars[index] == "\\" {
                index += 2
                continue
            }
            if scalars[index] == closing {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    private static func endOfWord(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count, isWordScalar(scalars[index]) {
            index += 1
        }
        return index
    }

    private static func wordOnlyReads(_ scalars: [Unicode.Scalar], start: Int, end: Int) -> Bool {
        let word = String(String.UnicodeScalarView(scalars[start..<end]))
        if isFollowedByPathSeparator(scalars, at: end), writingFunctionNamespaces.contains(word.lowercased()) {
            return false
        }
        if namesParameterFieldOrFunction(scalars, start: start) {
            return true
        }
        return !writingKeywords.contains(word.uppercased())
    }

    private static func namesParameterFieldOrFunction(_ scalars: [Unicode.Scalar], start: Int) -> Bool {
        guard start > 0 else { return false }
        switch scalars[start - 1] {
        case "$":
            return true
        case ".":
            return start >= 2 && scalars[start - 2] != "."
        case ":":
            return start >= 3 && scalars[start - 2] == ":" && isWordScalar(scalars[start - 3])
        default:
            return false
        }
    }

    private static func isFollowedByPathSeparator(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var next = index
        while next < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[next]) {
            next += 1
        }
        return next + 1 < scalars.count && scalars[next] == ":" && scalars[next + 1] == ":"
    }

    private static func startsStatementOrComment(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let next = index + 1 < scalars.count ? scalars[index + 1] : nil
        switch scalars[index] {
        case ";", "#":
            return true
        case "-":
            return next == "-"
        case "/":
            return next == "/" || next == "*"
        default:
            return false
        }
    }
}
