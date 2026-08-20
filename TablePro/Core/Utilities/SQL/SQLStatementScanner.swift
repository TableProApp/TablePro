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
        let hasContent: Bool

        init(sql: String, offset: Int, hasContent: Bool = true) {
            self.sql = sql
            self.offset = offset
            self.hasContent = hasContent
        }

        /// The statement's whole span in the document, in UTF-16 units.
        var range: NSRange {
            NSRange(location: offset, length: (sql as NSString).length)
        }

        /// The span of the statement's own text, with the inherited whitespace trimmed off both ends.
        ///
        /// `offset` is the index just past the previous semicolon, so in a script written one statement per line it
        /// lands on the newline that ended the previous line. A decoration or a gutter anchor placed from ``range``
        /// therefore starts a line early, and uses this instead.
        var contentRange: NSRange {
            let text = sql as NSString
            var start = 0
            var end = text.length
            while start < end, SqlLexer.isWhitespace(text.character(at: start)) {
                start += 1
            }
            while end > start, SqlLexer.isWhitespace(text.character(at: end - 1)) {
                end -= 1
            }
            return NSRange(location: offset + start, length: end - start)
        }
    }

    /// Every statement in the document, with its span, in document order.
    ///
    /// Unlike ``allStatements(in:dialect:)`` this keeps the empty and comment-only segments, flagged by
    /// ``LocatedStatement/hasContent``, because a caller drawing per-statement decorations has to be able to tell a
    /// segment that carries nothing from one that was never scanned.
    static func locatedStatements(in sql: String, dialect: SqlDialect = .generic) -> [LocatedStatement] {
        var results: [LocatedStatement] = []
        scan(sql: sql, cursorPosition: nil, dialect: dialect) { rawSQL, offset, hasStatementContent in
            results.append(LocatedStatement(sql: rawSQL, offset: offset, hasContent: hasStatementContent))
            return true
        }
        return results
    }

    /// Returns statements with trailing semicolons stripped, for driver execution.
    static func allStatements(in sql: String, dialect: SqlDialect = .generic) -> [String] {
        var results: [String] = []
        scan(sql: sql, cursorPosition: nil, dialect: dialect) { rawSQL, _, hasStatementContent in
            guard hasStatementContent else { return true }
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
        scan(sql: sql, cursorPosition: nil) { rawSQL, _, hasStatementContent in
            guard hasStatementContent else { return true }
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
        var result = LocatedStatement(sql: "", offset: 0, hasContent: false)
        scan(sql: sql, cursorPosition: cursorPosition, dialect: dialect) { rawSQL, offset, hasStatementContent in
            result = LocatedStatement(sql: rawSQL, offset: offset, hasContent: hasStatementContent)
            return false
        }
        return result
    }

    // MARK: - Private

    private static func scan(
        sql: String,
        cursorPosition: Int?,
        dialect: SqlDialect = .generic,
        onStatement: (_ rawSQL: String, _ offset: Int, _ hasStatementContent: Bool) -> Bool
    ) {
        let nsQuery = sql as NSString
        let length = nsQuery.length
        guard length > 0 else { return }

        let safePosition = cursorPosition.map { min(max(0, $0), length) }

        var currentStart = 0
        var inString = false
        var stringCharVal: UInt16 = 0
        var inLineComment = false
        var inBlockComment = false
        var inDollarQuote = false
        var dollarTag = ""
        var hasStatementContent = false
        var opensRoutineDefinition = false
        var sawStatementKeyword = false
        var blockDepth = 0
        let dollarQuotesEnabled = dialect.supportsDollarQuotes
        let hashCommentsEnabled = dialect.supportsHashLineComments
        var i = 0

        while i < length {
            let ch = nsQuery.character(at: i)

            if inLineComment {
                if ch == SqlLexer.newline { inLineComment = false }
                i += 1
                continue
            }

            if inBlockComment {
                if ch == SqlLexer.star && i + 1 < length && nsQuery.character(at: i + 1) == SqlLexer.slash {
                    inBlockComment = false
                    i += 2
                    continue
                }
                i += 1
                continue
            }

            if inDollarQuote {
                if ch == SqlDollarQuote.dollar,
                   SqlDollarQuote.matchesClose(at: i, tag: dollarTag, in: nsQuery, bufLen: length) {
                    inDollarQuote = false
                    i += (dollarTag as NSString).length + 2
                    dollarTag = ""
                    continue
                }
                i += 1
                continue
            }

            if !inString && SqlLexer.startsLineComment(nsQuery, at: i, length: length) {
                inLineComment = true
                i += 2
                continue
            }

            if !inString && hashCommentsEnabled && ch == SqlLexer.hash {
                inLineComment = true
                i += 1
                continue
            }

            if !inString && SqlLexer.startsBlockComment(nsQuery, at: i, length: length) {
                if SqlLexer.startsConditionalComment(nsQuery, at: i, length: length) {
                    hasStatementContent = true
                }
                inBlockComment = true
                i += 2
                continue
            }

            if inString && ch == SqlLexer.backslash && i + 1 < length {
                i += 2
                continue
            }

            if SqlLexer.isQuote(ch) {
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

            if dollarQuotesEnabled, !inString, ch == SqlDollarQuote.dollar,
               case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(at: i, in: nsQuery, bufLen: length) {
                inDollarQuote = true
                dollarTag = tag
                hasStatementContent = true
                i += openerLength
                continue
            }

            if !inString, SqlDollarQuote.isIdentifierStart(ch) {
                let word = SqlBlockStructure.readKeyword(nsQuery, at: i, length: length)
                if !sawStatementKeyword {
                    sawStatementKeyword = true
                    opensRoutineDefinition = SqlBlockStructure.opensRoutineDefinition(word.text)
                }
                hasStatementContent = true
                switch SqlBlockStructure.effect(
                    of: word.text,
                    endingAt: word.end,
                    in: nsQuery,
                    length: length,
                    allowsBlock: opensRoutineDefinition
                ) {
                case .opensBlock:
                    blockDepth += 1
                case .closesBlock:
                    blockDepth = max(0, blockDepth - 1)
                case .none:
                    break
                }
                i = word.end
                continue
            }

            if ch == SqlLexer.semicolon && !inString && blockDepth > 0 {
                hasStatementContent = true
                i += 1
                continue
            }

            if ch == SqlLexer.semicolon && !inString {
                let stmtEnd = i + 1

                if let cursor = safePosition {
                    if cursor >= currentStart && cursor <= stmtEnd {
                        let stmtRange = NSRange(location: currentStart, length: stmtEnd - currentStart)
                        _ = onStatement(nsQuery.substring(with: stmtRange), currentStart, hasStatementContent)
                        return
                    }
                } else {
                    let stmtRange = NSRange(location: currentStart, length: stmtEnd - currentStart)
                    if !onStatement(nsQuery.substring(with: stmtRange), currentStart, hasStatementContent) { return }
                }

                currentStart = stmtEnd
                hasStatementContent = false
                sawStatementKeyword = false
                opensRoutineDefinition = false
                blockDepth = 0
            } else if !SqlLexer.isWhitespace(ch) {
                hasStatementContent = true
            }

            i += 1
        }

        if currentStart < length {
            let stmtRange = NSRange(location: currentStart, length: length - currentStart)
            _ = onStatement(nsQuery.substring(with: stmtRange), currentStart, hasStatementContent)
        }
    }
}
