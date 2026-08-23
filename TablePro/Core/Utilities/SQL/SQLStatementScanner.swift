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

    /// One statement as the driver will receive it, with the span of the text it was taken from.
    ///
    /// `sql` is the semicolon-stripped, trimmed form; `range` covers exactly those characters, so a caller that keeps
    /// the range can find its way back to the statement it ran.
    ///
    /// The range is relative to the text the scan was given. A run started from a selection or from a single
    /// statement scans a fragment, so those callers shift the range onto the tab's whole query with ``offset(by:)``
    /// before it travels any further. Everything downstream may then assume tab coordinates.
    struct ExecutableStatement {
        let sql: String
        let range: NSRange

        func offset(by delta: Int) -> ExecutableStatement {
            guard delta != 0 else { return self }
            return ExecutableStatement(
                sql: sql,
                range: NSRange(location: range.location + delta, length: range.length)
            )
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

    /// The statements a reader can act on, in document order.
    ///
    /// Everything the editor offers per statement is drawn from this one filter: the gutter's run controls, the
    /// caret-statement band and the navigation commands. A segment that carries nothing, meaning a comment or trailing
    /// whitespace, is not somewhere a caret should be sent and not something worth offering to run, so it is dropped
    /// here rather than at each call site where the three could drift apart.
    static func navigableStatements(in sql: String, dialect: SqlDialect = .generic) -> [LocatedStatement] {
        locatedStatements(in: sql, dialect: dialect)
            .filter { $0.hasContent && $0.contentRange.length > 0 }
    }

    /// Where the caret goes when the reader asks for the statement after the one it is in.
    ///
    /// Returns `nil` at the end of the document rather than wrapping. Wrapping a caret to the other end of a script is
    /// a jump the reader did not ask for and cannot take back with the opposite key.
    ///
    /// A caret sitting in the trivia between two statements belongs to neither, so this answers with the next
    /// statement that starts after it.
    static func statementStart(
        after offset: Int,
        in sql: String,
        dialect: SqlDialect = .generic
    ) -> Int? {
        var found: Int?
        scan(sql: sql, cursorPosition: nil, dialect: dialect) { rawSQL, statementOffset, hasStatementContent in
            let statement = LocatedStatement(sql: rawSQL, offset: statementOffset, hasContent: hasStatementContent)
            guard statement.hasContent, statement.contentRange.length > 0 else { return true }
            guard statement.contentRange.location > offset else { return true }
            found = statement.contentRange.location
            return false
        }
        return found
    }

    /// How far `Option+Shift+Down` reaches.
    ///
    /// Selection wants the far edge of the text, not the start of the next statement, or the last statement's own body
    /// could never be selected: past its start there is no next statement to reach for.
    static func statementSelectionEnd(
        after offset: Int,
        in sql: String,
        dialect: SqlDialect = .generic
    ) -> Int? {
        if let next = statementStart(after: offset, in: sql, dialect: dialect) {
            return next
        }
        let end = navigableStatements(in: sql, dialect: dialect).last?.contentRange.upperBound
        return end.flatMap { $0 > offset ? $0 : nil }
    }

    /// Where the caret goes when the reader asks for the statement before the one it is in.
    ///
    /// A caret already past the start of its own statement goes to that statement's start first, which is how a
    /// reader steps back through a script without overshooting the statement they were reading.
    static func statementStart(
        before offset: Int,
        in sql: String,
        dialect: SqlDialect = .generic
    ) -> Int? {
        var found: Int?
        scan(sql: sql, cursorPosition: nil, dialect: dialect) { rawSQL, statementOffset, hasStatementContent in
            let statement = LocatedStatement(sql: rawSQL, offset: statementOffset, hasContent: hasStatementContent)
            guard statement.hasContent, statement.contentRange.length > 0 else { return true }
            guard statement.contentRange.location < offset else { return false }
            found = statement.contentRange.location
            return true
        }
        return found
    }

    /// Returns statements with trailing semicolons stripped, for driver execution.
    static func allStatements(in sql: String, dialect: SqlDialect = .generic) -> [String] {
        executableStatements(in: sql, dialect: dialect).map(\.sql)
    }

    /// The same statements ``allStatements(in:dialect:)`` returns, each with its span in the document.
    ///
    /// One enumeration produces both, because the alternative is two filters that have to agree and that nothing
    /// checks. ``navigableStatements(in:dialect:)`` is deliberately not that second filter: it trims only
    /// ``SqlLexer/isWhitespace`` and keeps the terminating semicolon, while execution trims the wider
    /// `.whitespacesAndNewlines` and strips one semicolon, so a segment can survive one and not the other. Pointing
    /// execution at the navigation filter would change which text reaches the driver, which is not a change a
    /// feature about labelling results is allowed to make.
    static func executableStatements(in sql: String, dialect: SqlDialect = .generic) -> [ExecutableStatement] {
        var results: [ExecutableStatement] = []
        scan(sql: sql, cursorPosition: nil, dialect: dialect) { rawSQL, offset, hasStatementContent in
            guard hasStatementContent,
                  let statement = executableStatement(rawSQL: rawSQL, offset: offset) else { return true }
            results.append(statement)
            return true
        }
        return results
    }

    private static func executableStatement(rawSQL: String, offset: Int) -> ExecutableStatement? {
        let text = rawSQL as NSString
        guard var range = trimmedRange(in: text, range: NSRange(location: 0, length: text.length)) else { return nil }

        if text.character(at: range.upperBound - 1) == semicolon {
            range.length -= 1
            guard let withoutSemicolon = trimmedRange(in: text, range: range) else { return nil }
            range = withoutSemicolon
        }

        return ExecutableStatement(
            sql: text.substring(with: range),
            range: NSRange(location: offset + range.location, length: range.length)
        )
    }

    /// The span of `range` with `.whitespacesAndNewlines` trimmed off both ends, or `nil` when nothing is left.
    ///
    /// Matches what `String.trimmingCharacters(in:)` would produce, but in UTF-16 offsets, so the text and the span
    /// handed to a caller describe the same characters by construction rather than by two separate calculations.
    private static func trimmedRange(in text: NSString, range: NSRange) -> NSRange? {
        let content = CharacterSet.whitespacesAndNewlines.inverted
        let first = text.rangeOfCharacter(from: content, options: [], range: range)
        guard first.location != NSNotFound else { return nil }
        let last = text.rangeOfCharacter(from: content, options: .backwards, range: range)
        return NSRange(location: first.location, length: last.upperBound - first.location)
    }

    private static let semicolon: unichar = 59

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
