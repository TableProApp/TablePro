//
//  SQLStatementScanner.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum SQLStatementScanner {
    struct LocatedStatement {
        let sql: String
        let offset: Int
    }

    /// Returns statements with trailing semicolons stripped, for driver execution.
    static func allStatements(in sql: String, dialect: SqlDialect = .generic) -> [String] {
        var results: [String] = []
        scan(sql: sql, cursorPosition: nil, dialect: dialect) { rawSQL, _ in
            var trimmed = rawSQL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix(";") {
                trimmed = String(trimmed.dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !trimmed.isEmpty {
                results.append(trimmed)
            }
            return true
        }
        return results
    }

    /// Returns statements preserving trailing semicolons, for display/history/favorites.
    static func allStatementsPreservingSemicolons(in sql: String) -> [String] {
        var results: [String] = []
        scan(sql: sql, cursorPosition: nil) { rawSQL, _ in
            let trimmed = rawSQL.trimmingCharacters(in: .whitespacesAndNewlines)
            let withoutSemicolon = trimmed.hasSuffix(";")
                ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                : trimmed
            if !withoutSemicolon.isEmpty {
                results.append(trimmed)
            }
            return true
        }
        return results
    }

    static func statementAtCursor(in sql: String, cursorPosition: Int, dialect: SqlDialect = .generic) -> String {
        var result = locatedStatementAtCursor(in: sql, cursorPosition: cursorPosition, dialect: dialect)
            .sql
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasSuffix(";") {
            result = String(result.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func locatedStatementAtCursor(in sql: String, cursorPosition: Int, dialect: SqlDialect = .generic) -> LocatedStatement {
        var result = LocatedStatement(sql: "", offset: 0)
        scan(sql: sql, cursorPosition: cursorPosition, dialect: dialect) { rawSQL, offset in
            result = LocatedStatement(sql: rawSQL, offset: offset)
            return false
        }
        return result
    }

    // MARK: - Private

    private static let singleQuote = UInt16(UnicodeScalar("'").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)
    private static let semicolonChar = UInt16(UnicodeScalar(";").value)
    private static let dash = UInt16(UnicodeScalar("-").value)
    private static let slash = UInt16(UnicodeScalar("/").value)
    private static let star = UInt16(UnicodeScalar("*").value)
    private static let newline = UInt16(UnicodeScalar("\n").value)
    private static let backslash = UInt16(UnicodeScalar("\\").value)
    private static let dollar = UInt16(UnicodeScalar("$").value)

    private static func scan(
        sql: String,
        cursorPosition: Int?,
        dialect: SqlDialect = .generic,
        onStatement: (_ rawSQL: String, _ offset: Int) -> Bool
    ) {
        let nsQuery = sql as NSString
        let length = nsQuery.length
        guard length > 0 else { return }

        guard nsQuery.range(of: ";").location != NSNotFound else {
            _ = onStatement(sql, 0)
            return
        }

        let safePosition = cursorPosition.map { min(max(0, $0), length) }

        var currentStart = 0
        var inString = false
        var stringCharVal: UInt16 = 0
        var inLineComment = false
        var inBlockComment = false
        var inDollarQuote = false
        var dollarTag = ""
        let dollarQuotesEnabled = dialect.supportsDollarQuotes
        var i = 0

        while i < length {
            let ch = nsQuery.character(at: i)

            if inLineComment {
                if ch == newline { inLineComment = false }
                i += 1
                continue
            }

            if inBlockComment {
                if ch == star && i + 1 < length && nsQuery.character(at: i + 1) == slash {
                    inBlockComment = false
                    i += 2
                    continue
                }
                i += 1
                continue
            }

            if inDollarQuote {
                if ch == dollar,
                   SqlDollarQuote.matchesClose(at: i, tag: dollarTag, in: nsQuery, bufLen: length) {
                    inDollarQuote = false
                    i += (dollarTag as NSString).length + 2
                    dollarTag = ""
                    continue
                }
                i += 1
                continue
            }

            if !inString && ch == dash && i + 1 < length && nsQuery.character(at: i + 1) == dash {
                inLineComment = true
                i += 2
                continue
            }

            if !inString && ch == slash && i + 1 < length && nsQuery.character(at: i + 1) == star {
                inBlockComment = true
                i += 2
                continue
            }

            if inString && ch == backslash && i + 1 < length {
                i += 2
                continue
            }

            if ch == singleQuote || ch == doubleQuote || ch == backtick {
                if !inString {
                    inString = true
                    stringCharVal = ch
                } else if ch == stringCharVal {
                    if i + 1 < length && nsQuery.character(at: i + 1) == stringCharVal {
                        i += 1
                    } else {
                        inString = false
                    }
                }
            }

            if dollarQuotesEnabled, !inString, ch == dollar,
               case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(at: i, in: nsQuery, bufLen: length) {
                inDollarQuote = true
                dollarTag = tag
                i += openerLength
                continue
            }

            if ch == semicolonChar && !inString {
                let stmtEnd = i + 1

                if let cursor = safePosition {
                    if cursor >= currentStart && cursor <= stmtEnd {
                        let stmtRange = NSRange(location: currentStart, length: stmtEnd - currentStart)
                        _ = onStatement(nsQuery.substring(with: stmtRange), currentStart)
                        return
                    }
                } else {
                    let stmtRange = NSRange(location: currentStart, length: stmtEnd - currentStart)
                    if !onStatement(nsQuery.substring(with: stmtRange), currentStart) { return }
                }

                currentStart = stmtEnd
            }

            i += 1
        }

        if currentStart < length {
            let stmtRange = NSRange(location: currentStart, length: length - currentStart)
            _ = onStatement(nsQuery.substring(with: stmtRange), currentStart)
        }
    }
}
