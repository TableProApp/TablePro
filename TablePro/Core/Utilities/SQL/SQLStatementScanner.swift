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
        let terminator: SQLStatementTerminator
        let acceptsBindParameters: Bool

        init(
            sql: String,
            offset: Int,
            hasContent: Bool = true,
            terminator: SQLStatementTerminator = .separator,
            acceptsBindParameters: Bool = true
        ) {
            self.sql = sql
            self.offset = offset
            self.hasContent = hasContent
            self.terminator = terminator
            self.acceptsBindParameters = acceptsBindParameters
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
            let content = StatementBlank.contentRange(of: sql)
            return NSRange(location: offset + content.location, length: content.length)
        }
    }

    /// One statement as the driver will receive it, with the span of the text it was taken from.
    ///
    /// `sql` is the trimmed form, with the terminating `;` stripped unless it belongs to the statement, as it does
    /// after a PL/SQL unit's `END`; `range` covers exactly those characters, so a caller that keeps the range can find
    /// its way back to the statement it ran.
    ///
    /// The range is relative to the text the scan was given. A run started from a selection or from a single
    /// statement scans a fragment, so those callers shift the range onto the tab's whole query with ``offset(by:)``
    /// before it travels any further. Everything downstream may then assume tab coordinates.
    struct ExecutableStatement {
        let sql: String
        let range: NSRange

        /// False for a definition, whose `:name` is never a bind parameter; see
        /// ``SQLStatementBoundaryTracking/acceptsBindParameters``.
        let acceptsBindParameters: Bool

        init(sql: String, range: NSRange, acceptsBindParameters: Bool = true) {
            self.sql = sql
            self.range = range
            self.acceptsBindParameters = acceptsBindParameters
        }

        func offset(by delta: Int) -> ExecutableStatement {
            guard delta != 0 else { return self }
            return ExecutableStatement(
                sql: sql,
                range: NSRange(location: range.location + delta, length: range.length),
                acceptsBindParameters: acceptsBindParameters
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
        scan(sql: sql, cursorPosition: nil, dialect: dialect) { statement in
            results.append(statement)
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
        scan(sql: sql, cursorPosition: nil, dialect: dialect) { statement in
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
        scan(sql: sql, cursorPosition: nil, dialect: dialect) { statement in
            guard statement.hasContent, statement.contentRange.length > 0 else { return true }
            guard statement.contentRange.location < offset else { return false }
            found = statement.contentRange.location
            return true
        }
        return found
    }

    /// Returns statements as the driver receives them, for driver execution.
    static func allStatements(in sql: String, dialect: SqlDialect = .generic) -> [String] {
        executableStatements(in: sql, dialect: dialect).map(\.sql)
    }

    /// The same statements ``allStatements(in:dialect:)`` returns, each with its span in the document.
    ///
    /// One enumeration produces both, because the alternative is two filters that have to agree and that nothing
    /// checks. ``navigableStatements(in:dialect:)`` is deliberately not that second filter: it keeps the terminating
    /// semicolon, while execution strips one, so pointing execution at it would change which text reaches the driver.
    static func executableStatements(in sql: String, dialect: SqlDialect = .generic) -> [ExecutableStatement] {
        var results: [ExecutableStatement] = []
        scan(sql: sql, cursorPosition: nil, dialect: dialect) { located in
            guard located.hasContent, let statement = executableStatement(from: located) else { return true }
            results.append(statement)
            return true
        }
        return results
    }

    /// `text` as a driver receives it when it is sent whole: trimmed, and ending where its last statement's executable
    /// form ends, so a trailing separator comes off and a terminator that belongs to the statement stays. Empty when
    /// nothing but separators, comments or blanks is left.
    static func executableText(of text: String, dialect: SqlDialect) -> String {
        let trimmed = StatementBlank.trimming(text)
        guard let last = executableStatements(in: trimmed, dialect: dialect).last else { return "" }
        let end = last.range.location + last.range.length
        return StatementBlank.trimming((trimmed as NSString).substring(to: end))
    }

    /// The text the driver receives for `located`, or nil when nothing but a separator is left.
    ///
    /// A `;` that belongs to the statement stays, but only when there is something before it: a unit reduced to its
    /// terminator is as empty as any other.
    static func executableStatement(from located: LocatedStatement) -> ExecutableStatement? {
        let rawSQL = located.sql
        var content = StatementBlank.trimming(rawSQL[...])
        if content.last == ";" {
            let body = StatementBlank.trimming(content.dropLast())
            guard !body.isEmpty else { return nil }
            if located.terminator == .separator {
                content = body
            }
        }
        guard !content.isEmpty else { return nil }

        let range = NSRange(content.startIndex..<content.endIndex, in: rawSQL)
        return ExecutableStatement(
            sql: String(content),
            range: NSRange(location: located.offset + range.location, length: range.length),
            acceptsBindParameters: located.acceptsBindParameters
        )
    }

    /// Returns statements preserving trailing semicolons, for display/history/favorites.
    static func allStatementsPreservingSemicolons(in sql: String) -> [String] {
        var results: [String] = []
        scan(sql: sql, cursorPosition: nil) { statement in
            guard statement.hasContent else { return true }
            let trimmed = StatementBlank.trimming(statement.sql)
            let withoutSemicolon = trimmed.hasSuffix(";")
                ? StatementBlank.trimming(String(trimmed.dropLast()))
                : trimmed
            if !withoutSemicolon.isEmpty {
                results.append(trimmed)
            }
            return true
        }
        return results
    }

    static func statementAtCursor(in sql: String, cursorPosition: Int, dialect: SqlDialect = .generic) -> String {
        let located = locatedStatementAtCursor(in: sql, cursorPosition: cursorPosition, dialect: dialect)
        return executableStatement(from: located)?.sql ?? ""
    }

    static func locatedStatementAtCursor(in sql: String, cursorPosition: Int, dialect: SqlDialect = .generic) -> LocatedStatement {
        var result = LocatedStatement(sql: "", offset: 0, hasContent: false)
        scan(sql: sql, cursorPosition: cursorPosition, dialect: dialect) { statement in
            result = statement
            return false
        }
        return result
    }

    // MARK: - Private

    /// Walks the document once and hands each segment to `onStatement`, which returns false to stop.
    ///
    /// Segments tile the document: a statement runs from the end of the previous one to its terminator, so it carries
    /// the whitespace before it. With a `cursorPosition`, only the segment holding it is reported, or the last one
    /// when the cursor sits past every terminator. Where a statement ends is the tracker's decision; this loop only
    /// lexes, so a `;` inside a string, a comment or a quoted body never reaches it.
    private static func scan(
        sql: String,
        cursorPosition: Int?,
        dialect: SqlDialect = .generic,
        onStatement: (LocatedStatement) -> Bool
    ) {
        let nsQuery = sql as NSString
        let length = nsQuery.length
        guard length > 0 else { return }

        let safePosition = cursorPosition.map { min(max(0, $0), length) }

        var tracker = SQLStatementBoundaries.makeTracker(for: dialect)
        var nonCode = NonCodeSpan(backslashEscapes: dialect != .oracle)
        var currentStart = 0
        var hasStatementContent = false
        let dollarQuotesEnabled = dialect.supportsDollarQuotes
        let hashCommentsEnabled = dialect.supportsHashLineComments
        var i = 0

        var lastStatementWithContent: LocatedStatement?

        /// Reports the segment ending at `end` and starts the next one there. Returns false when the scan is done.
        ///
        /// A caret on a SQL*Plus `/` line stands for the statement the slash ends, which is where a reader who has
        /// just typed the slash expects `Cmd+Enter` to act.
        func finishSegment(at end: Int, hasContent: Bool, endsWithSlash: Bool = false) -> Bool {
            let statement = LocatedStatement(
                sql: nsQuery.substring(with: NSRange(location: currentStart, length: end - currentStart)),
                offset: currentStart,
                hasContent: hasContent,
                terminator: tracker.terminator,
                acceptsBindParameters: tracker.acceptsBindParameters
            )
            if hasContent {
                lastStatementWithContent = statement
            }
            if let cursor = safePosition {
                guard cursor >= currentStart, cursor <= end else {
                    currentStart = end
                    return true
                }
                _ = onStatement(endsWithSlash ? lastStatementWithContent ?? statement : statement)
                return false
            }
            currentStart = end
            return onStatement(statement)
        }

        while i < length {
            let ch = nsQuery.character(at: i)

            if nonCode.isOpen {
                i = nonCode.advance(from: i, in: nsQuery, length: length)
                continue
            }

            if SqlLexer.startsLineComment(nsQuery, at: i, length: length) {
                nonCode.state = .lineComment
                i += 2
                continue
            }

            if hashCommentsEnabled && ch == SqlLexer.hash {
                nonCode.state = .lineComment
                i += 1
                continue
            }

            if SqlLexer.startsBlockComment(nsQuery, at: i, length: length) {
                if SqlLexer.startsConditionalComment(nsQuery, at: i, length: length) {
                    hasStatementContent = true
                }
                nonCode.state = .blockComment
                i += 2
                continue
            }

            if SqlLexer.isQuote(ch) {
                nonCode.state = .string(quote: ch)
                hasStatementContent = true
                tracker.observeOpaqueToken()
                i += 1
                continue
            }

            if dollarQuotesEnabled, ch == SqlDollarQuote.dollar,
               case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(at: i, in: nsQuery, bufLen: length) {
                nonCode.state = .dollarQuote(tag: tag)
                hasStatementContent = true
                tracker.observeOpaqueToken()
                i += openerLength
                continue
            }

            if SqlBlockStructure.startsWord(nsQuery, at: i, length: length, dialect: dialect) {
                hasStatementContent = true
                if dialect.supportsAlternativeQuoting,
                   let literal = SqlLexer.skipAlternativeQuotedString(nsQuery, at: i, length: length) {
                    tracker.observeOpaqueToken()
                    i = literal.next
                    continue
                }
                if tracker.needsWords {
                    let word = SqlBlockStructure.readKeyword(nsQuery, at: i, length: length, dialect: dialect)
                    tracker.observeWord(word.text)
                    i = word.end
                } else {
                    i += 1
                    while i < length, SqlBlockStructure.continuesWord(nsQuery.character(at: i), dialect: dialect) {
                        i += 1
                    }
                }
                continue
            }

            if ch == SqlLexer.semicolon {
                guard tracker.observeSemicolon() else {
                    hasStatementContent = true
                    i += 1
                    continue
                }
                guard finishSegment(at: i + 1, hasContent: hasStatementContent) else { return }
                tracker.reset()
                hasStatementContent = false
                i += 1
                continue
            }

            if dialect.endsStatementsAtSlashLines, ch == SqlLexer.slash, isSlashLine(nsQuery, at: i, length: length) {
                if hasStatementContent {
                    guard finishSegment(at: i, hasContent: true) else { return }
                }
                guard finishSegment(at: i + 1, hasContent: false, endsWithSlash: true) else { return }
                tracker.reset()
                hasStatementContent = false
                i += 1
                continue
            }

            let blankLength = StatementBlank.blankLength(in: nsQuery, at: i)
            if blankLength > 0 {
                i += blankLength
                continue
            }
            hasStatementContent = true
            tracker.observeSymbol(ch)
            i += 1
        }

        if currentStart < length {
            let statement = LocatedStatement(
                sql: nsQuery.substring(with: NSRange(location: currentStart, length: length - currentStart)),
                offset: currentStart,
                hasContent: hasStatementContent,
                terminator: tracker.terminator,
                acceptsBindParameters: tracker.acceptsBindParameters
            )
            _ = onStatement(statement)
        }
    }

    /// The literal or comment the scan is inside, where nothing is a token and no `;` ends anything.
    private struct NonCodeSpan {
        enum State: Equatable {
            case code
            case lineComment
            case blockComment
            case string(quote: UInt16)
            case dollarQuote(tag: String)
        }

        var state = State.code

        /// Whether a backslash keeps a string open. Every dialect but Oracle is scanned as if it did, which only ever
        /// merges two statements; Oracle never escapes with one.
        let backslashEscapes: Bool

        var isOpen: Bool {
            state != .code
        }

        /// Steps past one unit of the open span, closing it where it ends, and returns the next offset.
        mutating func advance(from i: Int, in text: NSString, length: Int) -> Int {
            let ch = text.character(at: i)
            switch state {
            case .code:
                return i + 1
            case .lineComment:
                if ch == SqlLexer.newline { state = .code }
                return i + 1
            case .blockComment:
                guard ch == SqlLexer.star, i + 1 < length, text.character(at: i + 1) == SqlLexer.slash else {
                    return i + 1
                }
                state = .code
                return i + 2
            case let .dollarQuote(tag):
                guard ch == SqlDollarQuote.dollar,
                      SqlDollarQuote.matchesClose(at: i, tag: tag, in: text, bufLen: length) else {
                    return i + 1
                }
                state = .code
                return i + (tag as NSString).length + 2
            case let .string(quote):
                if backslashEscapes, ch == SqlLexer.backslash, i + 1 < length {
                    return i + 2
                }
                guard ch == quote else { return i + 1 }
                if i + 1 < length, text.character(at: i + 1) == quote {
                    return i + 2
                }
                state = .code
                return i + 1
            }
        }
    }

    /// Whether the `/` at `offset` stands alone on its line, which is what makes it SQL*Plus's terminator rather than
    /// a division.
    static func isSlashLine(_ text: NSString, at offset: Int, length: Int) -> Bool {
        var before = offset - 1
        while before >= 0, isLineBlank(text.character(at: before)) {
            before -= 1
        }
        guard before < 0 || text.character(at: before) == SqlLexer.newline else { return false }
        var after = offset + 1
        while after < length, isLineBlank(text.character(at: after)) {
            after += 1
        }
        return after == length || text.character(at: after) == SqlLexer.newline
    }

    private static func isLineBlank(_ character: UInt16) -> Bool {
        character == SqlLexer.space || character == SqlLexer.tab || character == SqlLexer.carriageReturn
    }
}
