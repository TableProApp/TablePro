import Foundation

public enum SQLStatementScanner {
    public struct LocatedStatement: Sendable {
        public let sql: String
        public let offset: Int
        public let hasContent: Bool
        public let terminator: SQLStatementTerminator
        public let acceptsBindParameters: Bool

        public init(
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
        public var range: NSRange {
            NSRange(location: offset, length: (sql as NSString).length)
        }

        /// The span of the statement's own text, with the inherited whitespace trimmed off both ends.
        ///
        /// `offset` is the index just past the previous semicolon, so in a script written one statement per line it
        /// lands on the newline that ended the previous line. A decoration or a gutter anchor placed from ``range``
        /// therefore starts a line early, and uses this instead.
        public var contentRange: NSRange {
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
    public struct ExecutableStatement: Sendable {
        public let sql: String
        public let range: NSRange

        /// False for a definition, whose `:name` is never a bind parameter; see
        /// ``SQLStatementBoundaryTracking/acceptsBindParameters``.
        public let acceptsBindParameters: Bool

        public init(sql: String, range: NSRange, acceptsBindParameters: Bool = true) {
            self.sql = sql
            self.range = range
            self.acceptsBindParameters = acceptsBindParameters
        }

        public func offset(by delta: Int) -> ExecutableStatement {
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
    /// Unlike ``allStatements(in:grammar:)`` this keeps the empty and comment-only segments, flagged by
    /// ``LocatedStatement/hasContent``, because a caller drawing per-statement decorations has to be able to tell a
    /// segment that carries nothing from one that was never scanned.
    public static func locatedStatements(in sql: String, grammar: SQLLexicalGrammar) -> [LocatedStatement] {
        var results: [LocatedStatement] = []
        scan(sql: sql, cursorPosition: nil, grammar: grammar) { statement in
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
    public static func navigableStatements(in sql: String, grammar: SQLLexicalGrammar) -> [LocatedStatement] {
        locatedStatements(in: sql, grammar: grammar)
            .filter { $0.hasContent && $0.contentRange.length > 0 }
    }

    /// Where the caret goes when the reader asks for the statement after the one it is in.
    ///
    /// Returns `nil` at the end of the document rather than wrapping. Wrapping a caret to the other end of a script is
    /// a jump the reader did not ask for and cannot take back with the opposite key.
    ///
    /// A caret sitting in the trivia between two statements belongs to neither, so this answers with the next
    /// statement that starts after it.
    public static func statementStart(
        after offset: Int,
        in sql: String,
        grammar: SQLLexicalGrammar
    ) -> Int? {
        var found: Int?
        scan(sql: sql, cursorPosition: nil, grammar: grammar) { statement in
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
    public static func statementSelectionEnd(
        after offset: Int,
        in sql: String,
        grammar: SQLLexicalGrammar
    ) -> Int? {
        if let next = statementStart(after: offset, in: sql, grammar: grammar) {
            return next
        }
        let end = navigableStatements(in: sql, grammar: grammar).last?.contentRange.upperBound
        return end.flatMap { $0 > offset ? $0 : nil }
    }

    /// Where the caret goes when the reader asks for the statement before the one it is in.
    ///
    /// A caret already past the start of its own statement goes to that statement's start first, which is how a
    /// reader steps back through a script without overshooting the statement they were reading.
    public static func statementStart(
        before offset: Int,
        in sql: String,
        grammar: SQLLexicalGrammar
    ) -> Int? {
        var found: Int?
        scan(sql: sql, cursorPosition: nil, grammar: grammar) { statement in
            guard statement.hasContent, statement.contentRange.length > 0 else { return true }
            guard statement.contentRange.location < offset else { return false }
            found = statement.contentRange.location
            return true
        }
        return found
    }

    /// Every `GO` line in the document, in document order, each ending the batch before it.
    ///
    /// The scan that finds them is the one that divides statements, so a separator can never fall inside a statement
    /// and no statement can run across one. Empty for an engine whose scripts have no batches.
    public static func batchSeparators(in sql: String, grammar: SQLLexicalGrammar) -> [SQLBatchSeparator] {
        guard grammar.contains(.batchSeparatorLines) else { return [] }
        var separators: [SQLBatchSeparator] = []
        scan(sql: sql, cursorPosition: nil, grammar: grammar, onBatchSeparator: { separators.append($0) }) { _ in
            true
        }
        return separators
    }

    /// Returns statements as the driver receives them, for driver execution.
    public static func allStatements(in sql: String, grammar: SQLLexicalGrammar) -> [String] {
        executableStatements(in: sql, grammar: grammar).map(\.sql)
    }

    /// The same statements ``allStatements(in:grammar:)`` returns, each with its span in the document.
    ///
    /// One enumeration produces both, because the alternative is two filters that have to agree and that nothing
    /// checks. ``navigableStatements(in:grammar:)`` is deliberately not that second filter: it keeps the terminating
    /// semicolon, while execution strips one, so pointing execution at it would change which text reaches the driver.
    public static func executableStatements(in sql: String, grammar: SQLLexicalGrammar) -> [ExecutableStatement] {
        var results: [ExecutableStatement] = []
        scan(sql: sql, cursorPosition: nil, grammar: grammar) { located in
            guard located.hasContent, let statement = executableStatement(from: located) else { return true }
            results.append(statement)
            return true
        }
        return results
    }

    /// `text` as a driver receives it when it is sent whole: trimmed, and ending where its last statement's executable
    /// form ends, so a trailing separator comes off and a terminator that belongs to the statement stays. Empty when
    /// nothing but separators, comments or blanks is left.
    public static func executableText(of text: String, grammar: SQLLexicalGrammar) -> String {
        let trimmed = StatementBlank.trimming(text)
        guard let last = executableStatements(in: trimmed, grammar: grammar).last else { return "" }
        let end = last.range.location + last.range.length
        return StatementBlank.trimming((trimmed as NSString).substring(to: end))
    }

    /// The text the driver receives for `located`, or nil when nothing but a separator is left.
    ///
    /// A `;` that belongs to the statement stays, but only when there is something before it: a unit reduced to its
    /// terminator is as empty as any other.
    public static func executableStatement(from located: LocatedStatement) -> ExecutableStatement? {
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
    public static func allStatementsPreservingSemicolons(in sql: String, grammar: SQLLexicalGrammar) -> [String] {
        var results: [String] = []
        scan(sql: sql, cursorPosition: nil, grammar: grammar) { statement in
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

    public static func statementAtCursor(in sql: String, cursorPosition: Int, grammar: SQLLexicalGrammar) -> String {
        let located = locatedStatementAtCursor(in: sql, cursorPosition: cursorPosition, grammar: grammar)
        return executableStatement(from: located)?.sql ?? ""
    }

    public static func locatedStatementAtCursor(in sql: String, cursorPosition: Int, grammar: SQLLexicalGrammar) -> LocatedStatement {
        var result = LocatedStatement(sql: "", offset: 0, hasContent: false)
        scan(sql: sql, cursorPosition: cursorPosition, grammar: grammar) { statement in
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
    /// lexes, so a `;` inside a string, a comment or a quoted body never reaches it. A `GO` line is the exception: it
    /// ends the batch, so it ends whatever statement is open whatever the tracker thinks, and is a segment of its own
    /// that holds nothing to run.
    private static func scan(
        sql: String,
        cursorPosition: Int?,
        grammar: SQLLexicalGrammar,
        onBatchSeparator: (SQLBatchSeparator) -> Void = { _ in },
        onStatement: (LocatedStatement) -> Bool
    ) {
        let nsQuery = sql as NSString
        let length = nsQuery.length
        guard length > 0 else { return }

        let safePosition = cursorPosition.map { min(max(0, $0), length) }

        var tracker = SQLStatementBoundaries.makeTracker(for: grammar)
        var currentStart = 0
        var hasStatementContent = false
        var i = 0

        var lastStatementWithContent: LocatedStatement?

        /// Reports the segment ending at `end` and starts the next one there. Returns false when the scan is done.
        ///
        /// A caret on a SQL*Plus `/` line stands for the statement the slash ends, which is where a reader who has
        /// just typed the slash expects `Cmd+Enter` to act. A caret on a `GO` line stands for the last statement of the
        /// batch it ends, and for nothing when that batch is empty: the batch before is not the one the line ends.
        func finishSegment(at end: Int, hasContent: Bool, standsForEndedStatement: Bool = false) -> Bool {
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
                _ = onStatement(standsForEndedStatement ? lastStatementWithContent ?? statement : statement)
                return false
            }
            currentStart = end
            return onStatement(statement)
        }

        while i < length {
            let ch = nsQuery.character(at: i)

            if let span = SQLNonCodeSpan.span(at: i, in: nsQuery, grammar: grammar) {
                switch span.kind {
                case .lineComment, .blockComment:
                    break
                case .executableComment:
                    hasStatementContent = true
                case .quoted, .parameter:
                    hasStatementContent = true
                    tracker.observeOpaqueToken()
                }
                i = max(span.end, i + 1)
                continue
            }

            if grammar.contains(.batchSeparatorLines),
               let separator = SQLBatchSeparator.line(at: i, in: nsQuery, length: length, grammar: grammar) {
                onBatchSeparator(separator)
                if hasStatementContent {
                    guard finishSegment(at: i, hasContent: true) else { return }
                }
                let separatorEnd = NSMaxRange(separator.range)
                guard finishSegment(at: separatorEnd, hasContent: false, standsForEndedStatement: true) else { return }
                lastStatementWithContent = nil
                tracker.reset()
                hasStatementContent = false
                i = separatorEnd
                continue
            }

            if SqlBlockStructure.startsWord(nsQuery, at: i, length: length, grammar: grammar) {
                hasStatementContent = true
                if tracker.needsWords {
                    let word = SqlBlockStructure.readKeyword(nsQuery, at: i, length: length, grammar: grammar)
                    tracker.observeWord(word.text)
                    i = word.end
                } else {
                    i += 1
                    while i < length, SqlBlockStructure.continuesWord(nsQuery.character(at: i), grammar: grammar) {
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

            if grammar.contains(.slashLineTerminators), ch == SqlLexer.slash, isSlashLine(nsQuery, at: i, length: length) {
                if hasStatementContent {
                    guard finishSegment(at: i, hasContent: true) else { return }
                }
                guard finishSegment(at: i + 1, hasContent: false, standsForEndedStatement: true) else { return }
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

    /// Whether the `/` at `offset` stands alone on its line, which is what makes it SQL*Plus's terminator rather than
    /// a division.
    public static func isSlashLine(_ text: NSString, at offset: Int, length: Int) -> Bool {
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
