//
//  SQLStatementSplitting.swift
//  TableProPluginKit
//

import Foundation

/// Splits a batch into statements, and strips the comments in front of each one.
///
/// A plain `split(separator: ";")` is wrong in the one direction that costs a user their work.
/// `SELECT ';COMMIT;'` cuts into `SELECT '`, `COMMIT` and `'`, and that middle fragment is
/// indistinguishable from a real `COMMIT`: a driver reading it as one clears the flag protecting an
/// open transaction, and the release that follows rolls the transaction back. Comments hide the
/// other direction: `-- staging` on the line above `CREATE TEMPORARY TABLE` pushes the keyword off
/// the front, so a session-state check that reads the first word sees a comment and finds nothing.
///
/// So the scan tracks single quotes, double quotes, backticks, dollar-quoted bodies, `--` and `#`
/// line comments and `/* */` block comments, and a `;` inside any of them is not a separator.
/// Doubled quotes (`''`) and backslash escapes both keep the string open, because MySQL honours
/// the backslash form and DuckDB does not, and treating a literal as longer than it is only ever
/// merges two statements, which is the safe direction here.
public enum SQLStatementSplitting {
    public static func statements(in sql: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var scanner = Scanner()

        for character in sql {
            if scanner.consume(character) {
                current.append(character)
                continue
            }
            if character == ";" {
                statements.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        statements.append(current)

        return statements
            .map(stripLeadingComments)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Everything before the first token that is not a comment. A statement is classified by its
    /// first word, and a comment in front of it is not that word.
    ///
    /// `/*!50601 ... */`, and MariaDB's `/*M!100301 ... */`, are not comments. MySQL parses the
    /// body as SQL whenever the server is at least that version, and mysqldump writes its whole
    /// preamble that way, so stripping them hid every `SET` a restore ran. They are left whole for
    /// the driver that knows how to read them; to an engine that does treat them as comments the
    /// statement is one it does not recognise, which is what an ignored comment already was.
    public static func stripLeadingComments(_ statement: String) -> String {
        var remainder = Substring(statement)
        while true {
            let trimmed = remainder.drop(while: { $0.isWhitespace })
            if trimmed.hasPrefix("--") || trimmed.hasPrefix("#") {
                guard let newline = trimmed.firstIndex(where: { $0.isNewline }) else { return "" }
                remainder = trimmed[trimmed.index(after: newline)...]
                continue
            }
            if trimmed.hasPrefix("/*"), !isExecutableComment(trimmed) {
                guard let end = trimmed.range(of: "*/") else { return "" }
                remainder = trimmed[end.upperBound...]
                continue
            }
            return String(trimmed)
        }
    }

    private static func isExecutableComment(_ text: Substring) -> Bool {
        text.hasPrefix("/*!") || text.hasPrefix("/*M!")
    }

    /// Tracks whether the scan currently sits inside something a `;` cannot end.
    private struct Scanner {
        private enum State {
            case code
            case singleQuote
            case doubleQuote
            case backtick
            case lineComment
            case blockComment
        }

        private var state = State.code
        private var isEscaped = false
        private var previous: Character?

        /// Returns true when the character is part of a literal or comment, so the caller must not
        /// read it as a separator.
        mutating func consume(_ character: Character) -> Bool {
            defer { previous = character }

            switch state {
            case .code:
                if character == "'" { state = .singleQuote; return true }
                if character == "\"" { state = .doubleQuote; return true }
                if character == "`" { state = .backtick; return true }
                if character == "#" { state = .lineComment; return true }
                if character == "-", previous == "-" { state = .lineComment; return true }
                if character == "*", previous == "/" { state = .blockComment; return true }
                return false

            case .singleQuote, .doubleQuote, .backtick:
                if isEscaped { isEscaped = false; return true }
                if character == "\\" { isEscaped = true; return true }
                if character == closingQuote { state = .code }
                return true

            case .lineComment:
                if character.isNewline { state = .code }
                return true

            case .blockComment:
                if character == "/", previous == "*" { state = .code }
                return true
            }
        }

        private var closingQuote: Character {
            switch state {
            case .singleQuote: return "'"
            case .doubleQuote: return "\""
            case .backtick: return "`"
            default: return "\0"
            }
        }
    }
}
