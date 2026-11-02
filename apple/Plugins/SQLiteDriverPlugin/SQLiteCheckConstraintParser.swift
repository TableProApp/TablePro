//
//  SQLiteCheckConstraintParser.swift
//  SQLiteDriverPlugin
//

import Foundation
import TableProPluginKit

// SQLite keeps constraints only in `sqlite_master.sql`. Only named table-level checks are read: DROP CONSTRAINT needs a name.
enum SQLiteCheckConstraintParser {
    struct ParsedConstraint: Equatable {
        let name: String
        let expression: String
    }

    static func constraints(inCreateStatement statement: String) -> [ParsedConstraint] {
        guard let parsed = SQLiteTableDDL.parse(createTableSQL: statement) else { return [] }
        return parsed.entries.compactMap { $0.columnName == nil ? constraint(in: $0.text) : nil }
    }

    // `PRAGMA table_xinfo` reports that a column is generated, never how.
    static func generationExpressions(inCreateStatement statement: String) -> [String: String] {
        guard let parsed = SQLiteTableDDL.parse(createTableSQL: statement) else { return [:] }
        var expressions: [String: String] = [:]
        for entry in parsed.entries {
            guard let name = entry.columnName, let expression = generationExpression(in: entry.text) else { continue }
            expressions[name] = expression
        }
        return expressions
    }

    private static func constraint(in entry: String) -> ParsedConstraint? {
        let scalars = entry.unicodeScalars
        guard let afterConstraint = keyword("CONSTRAINT", in: scalars, at: codeStart(in: scalars, from: scalars.startIndex)),
              let (name, afterName) = identifier(in: scalars, at: codeStart(in: scalars, from: afterConstraint)),
              let afterCheck = keyword("CHECK", in: scalars, at: codeStart(in: scalars, from: afterName)),
              let expression = parenthesized(in: scalars, at: codeStart(in: scalars, from: afterCheck)) else { return nil }
        return ParsedConstraint(name: name, expression: expression)
    }

    // `GENERATED ALWAYS AS (…)` or its short form `AS (…)`, outside any literal, name, comment or parenthesis.
    private static func generationExpression(in entry: String) -> String? {
        let scalars = entry.unicodeScalars
        var depth = 0
        var previous: Unicode.Scalar?
        var index = scalars.startIndex
        while index < scalars.endIndex {
            if let end = endOfNonCode(in: scalars, at: index) {
                previous = nil
                index = end
                continue
            }
            let scalar = scalars[index]
            if depth == 0, !(previous.map(isIdentifierScalar) ?? false),
               let afterAs = keyword("AS", in: scalars, at: index),
               let expression = parenthesized(in: scalars, at: codeStart(in: scalars, from: afterAs)) {
                return expression
            }
            if scalar == "(" { depth += 1 }
            if scalar == ")" { depth -= 1 }
            previous = scalar
            index = scalars.index(after: index)
        }
        return nil
    }

    private static func keyword(_ word: String, in scalars: String.UnicodeScalarView, at start: String.Index) -> String.Index? {
        var index = start
        for expected in word.unicodeScalars {
            guard index < scalars.endIndex, asciiUppercased(scalars[index]) == expected else { return nil }
            index = scalars.index(after: index)
        }
        guard index == scalars.endIndex || !isIdentifierScalar(scalars[index]) else { return nil }
        return index
    }

    private static func identifier(in scalars: String.UnicodeScalarView, at start: String.Index) -> (String, String.Index)? {
        guard start < scalars.endIndex else { return nil }
        guard let closing = closingQuote(for: scalars[start]) else {
            let end = scalars[start...].firstIndex { !isIdentifierScalar($0) } ?? scalars.endIndex
            return end == start ? nil : (String(scalars[start..<end]), end)
        }
        var name = String.UnicodeScalarView()
        var index = scalars.index(after: start)
        while index < scalars.endIndex {
            let scalar = scalars[index]
            index = scalars.index(after: index)
            if scalar == closing {
                // A doubled quote is an escaped one; a bracket has no escape form.
                guard closing != "]", index < scalars.endIndex, scalars[index] == closing else { return (String(name), index) }
                index = scalars.index(after: index)
            }
            name.append(scalar)
        }
        return nil
    }

    private static func parenthesized(in scalars: String.UnicodeScalarView, at start: String.Index) -> String? {
        guard start < scalars.endIndex, scalars[start] == "(" else { return nil }
        var depth = 0
        var index = start
        while index < scalars.endIndex {
            if let end = endOfNonCode(in: scalars, at: index) {
                index = end
                continue
            }
            if scalars[index] == "(" { depth += 1 }
            if scalars[index] == ")" {
                depth -= 1
                if depth == 0 {
                    let content = String(scalars[scalars.index(after: start)..<index])
                    return content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            index = scalars.index(after: index)
        }
        return nil
    }

    private static func codeStart(in scalars: String.UnicodeScalarView, from start: String.Index) -> String.Index {
        var index = start
        while index < scalars.endIndex {
            if isWhitespace(scalars[index]) {
                index = scalars.index(after: index)
            } else if let end = endOfComment(in: scalars, at: index) {
                index = end
            } else {
                break
            }
        }
        return index
    }

    private static func endOfNonCode(in scalars: String.UnicodeScalarView, at start: String.Index) -> String.Index? {
        if let end = endOfComment(in: scalars, at: start) { return end }
        guard let closing = closingQuote(for: scalars[start]) else { return nil }
        // A doubled quote reads as a close and a reopen, which skips the same text.
        let afterOpen = scalars.index(after: start)
        return scalars[afterOpen...].firstIndex(of: closing).map { scalars.index(after: $0) } ?? scalars.endIndex
    }

    // An unterminated comment runs to the end, and only a line feed ends `--`, as in SQLite's lexer.
    private static func endOfComment(in scalars: String.UnicodeScalarView, at start: String.Index) -> String.Index? {
        let next = scalars.index(after: start)
        guard next < scalars.endIndex else { return nil }
        switch (scalars[start], scalars[next]) {
        case ("-", "-"):
            return scalars[next...].firstIndex(of: "\n").map { scalars.index(after: $0) } ?? scalars.endIndex
        case ("/", "*"):
            var index = scalars.index(after: next)
            while index < scalars.endIndex {
                let after = scalars.index(after: index)
                if scalars[index] == "*", after < scalars.endIndex, scalars[after] == "/" { return scalars.index(after: after) }
                index = after
            }
            return scalars.endIndex
        default:
            return nil
        }
    }

    private static func closingQuote(for opening: Unicode.Scalar) -> Unicode.Scalar? {
        switch opening {
        case "'", "\"", "`": opening
        case "[": "]"
        default: nil
        }
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\u{0C}" || scalar == "\r"
    }

    // SQLite reads every scalar past ASCII as part of a name.
    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        !scalar.isASCII || scalar == "_" || scalar == "$"
            || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    private static func asciiUppercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("a"..."z").contains(scalar) ? Unicode.Scalar(UInt8(scalar.value) - 32) : scalar
    }
}
