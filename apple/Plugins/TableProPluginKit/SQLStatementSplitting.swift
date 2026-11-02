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
/// ``statements(in:lexicalFeatures:)`` splits the way the engine lexes: pass the features of the
/// connection's own engine, so a `;` inside a dollar-quoted body, a nested comment or a bracketed
/// identifier stays where the engine keeps it.
///
/// ``statements(in:)`` is the older, engine-blind form. It tracks single quotes, double quotes,
/// backticks, `--` and `#` line comments and flat `/* */` block comments, and nothing else: a
/// dollar-quoted body is split at its first `;`. A backslash keeps any quote open, which is MySQL's
/// rule and not DuckDB's, so it can only ever merge two statements.
public enum SQLStatementSplitting {
    public static func statements(in sql: String, lexicalFeatures: SQLLexicalFeatures) -> [String] {
        let lexer = SQLFeatureLexer(sql, features: lexicalFeatures)
        var pieces: [String] = []
        var start = 0
        var index = 0
        while index < lexer.count {
            if let span = lexer.span(at: index) {
                index = max(span.end, index + 1)
                continue
            }
            if lexer.units[index] == semicolon {
                pieces.append(String(decoding: lexer.units[start..<index], as: UTF16.self))
                start = index + 1
            }
            index += 1
        }
        pieces.append(String(decoding: lexer.units[min(start, lexer.count)...], as: UTF16.self))

        return pieces
            .map { stripLeadingComments($0, lexicalFeatures: lexicalFeatures) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Everything before the first token that is not a comment, read by the engine's own comment
    /// rules. An executable comment the features declare is code and stays.
    public static func stripLeadingComments(_ statement: String, lexicalFeatures: SQLLexicalFeatures) -> String {
        let lexer = SQLFeatureLexer(statement, features: lexicalFeatures)
        var index = 0
        while index < lexer.count {
            if isWhitespace(lexer.units[index]) {
                index += 1
                continue
            }
            guard let span = lexer.span(at: index), span.kind == .comment else { break }
            index = max(span.end, index + 1)
        }
        return String(decoding: lexer.units[min(index, lexer.count)...], as: UTF16.self)
    }

    private static let semicolon: UInt16 = 0x3B

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || (unit >= 0x09 && unit <= 0x0D)
    }

    public static func statements(in sql: String) -> [String] {
        statements(in: sql, lexicalFeatures: engineBlindFeatures)
    }

    // mysqldump's `/*!50601 … */` and MariaDB's `/*M!100301 … */` preamble is code, so it stays.
    public static func stripLeadingComments(_ statement: String) -> String {
        stripLeadingComments(statement, lexicalFeatures: engineBlindFeatures)
    }

    // The engine-blind reading: quotes a backslash keeps open, backticks, `#` and `--` comments, and
    // executable comments as code. Read by the lexer, so a quote a combining mark follows still ends.
    private static let engineBlindFeatures: SQLLexicalFeatures = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backslashEscapesInBackticks,
        .backtickQuotes, .hashLineComments, .executableComments,
    ]
}
