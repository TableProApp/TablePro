//
//  SQLiteCheckConstraintParser.swift
//  SQLiteDriverPlugin
//
//  Reads table-level CHECK constraints out of a CREATE TABLE statement.
//  Compiled into the test target via project.yml.
//

import Foundation

/// SQLite has no catalog for constraints: `sqlite_master.sql` is the only record, so the
/// statement it stores is the source. Only table-level checks are read, because a column-level
/// `CHECK` has no name of its own and `ALTER TABLE ... DROP CONSTRAINT` needs one, so such a
/// constraint could be listed but never edited.
enum SQLiteCheckConstraintParser {
    struct ParsedConstraint: Equatable {
        let name: String
        let expression: String
    }

    static func constraints(inCreateStatement statement: String) -> [ParsedConstraint] {
        guard let body = tableBody(of: statement) else { return [] }
        var results: [ParsedConstraint] = []

        for clause in topLevelClauses(of: body) {
            guard let parsed = parseConstraint(clause) else { continue }
            results.append(parsed)
        }
        return results
    }

    /// The generation expression per column name. `PRAGMA table_xinfo` reports *that* a column is
    /// generated but never how, so the CREATE TABLE text is the only source for the expression.
    static func generationExpressions(inCreateStatement statement: String) -> [String: String] {
        guard let body = tableBody(of: statement) else { return [:] }
        var expressions: [String: String] = [:]

        for clause in topLevelClauses(of: body) {
            let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.uppercased().hasPrefix("CONSTRAINT "),
                  let (name, remainder) = readIdentifier(trimmed),
                  let expression = generationExpression(inColumnRemainder: remainder) else { continue }
            expressions[name] = expression
        }
        return expressions
    }

    /// Matches the `AS (` that introduces a generated column, with or without the optional
    /// `GENERATED ALWAYS` before it. Scanned over the original string rather than an uppercased
    /// copy, because `uppercased()` can change a string's length and its indices then do not
    /// correspond to the original's.
    private static func generationExpression(inColumnRemainder remainder: String) -> String? {
        var index = remainder.startIndex
        while index < remainder.endIndex {
            guard remainder[index] == "a" || remainder[index] == "A" else {
                index = remainder.index(after: index)
                continue
            }
            let previousIsBoundary = index == remainder.startIndex
                || remainder[remainder.index(before: index)].isWhitespace
            let afterA = remainder.index(after: index)
            guard previousIsBoundary, afterA < remainder.endIndex,
                  remainder[afterA] == "s" || remainder[afterA] == "S" else {
                index = remainder.index(after: index)
                continue
            }
            let tail = remainder[remainder.index(after: afterA)...].drop { $0.isWhitespace }
            if tail.first == "(" {
                return balancedParenthesesContent(String(tail))
            }
            index = remainder.index(after: index)
        }
        return nil
    }

    /// The text between the parenthesis that opens the column list and the one that closes it.
    private static func tableBody(of statement: String) -> String? {
        guard let open = statement.firstIndex(of: "(") else { return nil }
        var depth = 0
        var insideLiteral: Character?
        var index = open
        while index < statement.endIndex {
            let character = statement[index]
            if let quote = insideLiteral {
                if character == quote { insideLiteral = nil }
            } else if character == "'" || character == "\"" || character == "`" {
                insideLiteral = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return String(statement[statement.index(after: open)..<index])
                }
            }
            index = statement.index(after: index)
        }
        return nil
    }

    /// Splits on commas that are not inside parentheses or a quoted literal, so a multi-column
    /// check such as `CHECK (a > 0 AND length(b) < 10)` stays in one piece.
    private static func topLevelClauses(of body: String) -> [String] {
        var clauses: [String] = []
        var current = ""
        var depth = 0
        var insideLiteral: Character?

        for character in body {
            if let quote = insideLiteral {
                current.append(character)
                if character == quote { insideLiteral = nil }
                continue
            }
            switch character {
            case "'", "\"", "`":
                insideLiteral = character
                current.append(character)
            case "(":
                depth += 1
                current.append(character)
            case ")":
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                clauses.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clauses.append(current) }
        return clauses
    }

    private static func parseConstraint(_ clause: String) -> ParsedConstraint? {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("CONSTRAINT ") else { return nil }

        var remainder = String(trimmed.dropFirst("CONSTRAINT ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (name, afterName) = readIdentifier(remainder) else { return nil }
        remainder = afterName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard remainder.uppercased().hasPrefix("CHECK") else { return nil }
        remainder = String(remainder.dropFirst("CHECK".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expression = balancedParenthesesContent(remainder) else { return nil }

        return ParsedConstraint(name: name, expression: expression)
    }

    private static func readIdentifier(_ text: String) -> (String, String)? {
        guard let first = text.first else { return nil }
        let quotePairs: [Character: Character] = ["\"": "\"", "`": "`", "[": "]"]
        if let closing = quotePairs[first] {
            guard let end = text.dropFirst().firstIndex(of: closing) else { return nil }
            let name = String(text[text.index(after: text.startIndex)..<end])
            return (name, String(text[text.index(after: end)...]))
        }
        guard let end = text.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "(" }) else {
            return nil
        }
        return (String(text[text.startIndex..<end]), String(text[end...]))
    }

    private static func balancedParenthesesContent(_ text: String) -> String? {
        guard text.first == "(" else { return nil }
        var depth = 0
        var insideLiteral: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let quote = insideLiteral {
                if character == quote { insideLiteral = nil }
            } else if character == "'" || character == "\"" {
                insideLiteral = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    let content = text[text.index(after: text.startIndex)..<index]
                    return content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
