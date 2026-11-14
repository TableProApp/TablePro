import Foundation

public enum SQLStatementScanner {
    public struct LocatedStatement: Sendable {
        public let sql: String
        public let offset: Int
        public let hasContent: Bool
        public let terminator: SQLStatementTerminator
        public let acceptsBindParameters: Bool

        /// How many units at the end of ``sql`` are a client delimiter such as `//`, which no server receives. Zero when
        /// a `;` or nothing ends the statement.
        public let delimiterLength: Int

        /// For a `COPY ... FROM STDIN`, everything after its `;` that a psql script holds as rows, in the document's
        /// coordinates. None of it is SQL.
        public let copyRows: NSRange?

        /// The client delimiter in force once the statement ends.
        public let clientDelimiter: SQLClientDelimiter?

        /// A `DELIMITER` or psql `\restrict` line, which the client reads and no server receives.
        public let isClientLine: Bool
        private let isAllContent: Bool

        public init(
            sql: String,
            offset: Int,
            hasContent: Bool = true,
            terminator: SQLStatementTerminator = .separator,
            acceptsBindParameters: Bool = true,
            delimiterLength: Int = 0,
            copyRows: NSRange? = nil,
            clientDelimiter: SQLClientDelimiter? = nil,
            isClientLine: Bool = false
        ) {
            self.sql = sql
            self.offset = offset
            self.hasContent = hasContent
            self.terminator = terminator
            self.acceptsBindParameters = acceptsBindParameters
            self.delimiterLength = delimiterLength
            self.copyRows = copyRows
            self.clientDelimiter = clientDelimiter
            self.isClientLine = isClientLine
            isAllContent = false
        }

        // A Redis command starts and ends on an argument byte, which can be one StatementBlank trims.
        public init(wholeText sql: String, offset: Int) {
            self.sql = sql
            self.offset = offset
            hasContent = true
            terminator = .separator
            acceptsBindParameters = true
            delimiterLength = 0
            copyRows = nil
            clientDelimiter = nil
            isClientLine = false
            isAllContent = true
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
        ///
        /// A client delimiter is left out: Run Current scans the text again on its own, where no `DELIMITER` line
        /// precedes it, so the delimiter would reach the server.
        public var contentRange: NSRange {
            guard !isAllContent else { return range }
            let text = sql as NSString
            let content = StatementBlank.contentRange(of: text.substring(to: max(0, text.length - delimiterLength)))
            // A COPY's rows run to their end as written: a last row's trailing tab is a column.
            let end = copyRows.map { max(NSMaxRange(content), NSMaxRange($0) - offset) } ?? NSMaxRange(content)
            return NSRange(location: offset + content.location, length: end - content.location)
        }
    }

    /// One statement as the driver will receive it, with the span of the text it was taken from.
    ///
    /// `sql` is the trimmed form, with the terminating `;` stripped unless it belongs to the statement, as it does
    /// after a PL/SQL unit's `END` and after a T-SQL `MERGE`; `range` covers exactly those characters, so a caller that
    /// keeps the range can find its way back to the statement it ran.
    ///
    /// The range is relative to the text the scan was given. A run started from a selection or from a single
    /// statement scans a fragment, so those callers shift the range onto the tab's whole query with ``offset(by:)``
    /// before it travels any further. Everything downstream may then assume tab coordinates.
    public struct ExecutableStatement: Sendable, Equatable {
        public let sql: String
        public let range: NSRange

        /// False for a definition, whose `:name` is never a bind parameter; see
        /// ``SQLStatementBoundaryTracking/acceptsBindParameters``.
        public let acceptsBindParameters: Bool

        /// Where the scan went on after this statement: past its `;`, a client delimiter or a `COPY`'s rows. A run
        /// that splits the rest of a script again starts there, with ``clientDelimiter`` in force.
        public let segmentEnd: Int
        public let clientDelimiter: SQLClientDelimiter?

        // A `COPY ... FROM STDIN`'s rows as psql sends them, empty for a block with none; nil for any other statement.
        public let copyData: String?

        public init(
            sql: String,
            range: NSRange,
            acceptsBindParameters: Bool = true,
            segmentEnd: Int? = nil,
            clientDelimiter: SQLClientDelimiter? = nil,
            copyData: String? = nil
        ) {
            self.sql = sql
            self.range = range
            self.acceptsBindParameters = acceptsBindParameters
            self.segmentEnd = segmentEnd ?? NSMaxRange(range)
            self.clientDelimiter = clientDelimiter
            self.copyData = copyData
        }

        public func offset(by delta: Int) -> ExecutableStatement {
            guard delta != 0 else { return self }
            return ExecutableStatement(
                sql: sql,
                range: NSRange(location: range.location + delta, length: range.length),
                acceptsBindParameters: acceptsBindParameters,
                segmentEnd: segmentEnd + delta,
                clientDelimiter: clientDelimiter,
                copyData: copyData
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

    /// The text of a psql script a formatter keeps as written, in document order: each `COPY ... FROM STDIN` with the
    /// rows after it through the `\.` line, and pg_dump's `\restrict` and `\unrestrict` lines. Empty for an engine
    /// whose scripts are not psql's.
    public static func psqlScriptText(in sql: String, grammar: SQLLexicalGrammar) -> [NSRange] {
        guard grammar.contains(.psqlScripts) else { return [] }
        var ranges: [NSRange] = []
        scan(sql: sql, cursorPosition: nil, grammar: grammar, onScriptText: { ranges.append($0) }) { _ in true }
        return ranges
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

    /// `text` as a driver receives it when it is sent whole: starting where its first statement starts and ending where
    /// its last statement's executable form ends, so a separator on either side comes off and a terminator that belongs
    /// to the statement stays. A `GO` line ahead of the first statement is the client's word: SQL Server reads one it
    /// receives as a call to a procedure named `GO`. Empty when nothing but separators, comments or blanks is left.
    public static func executableText(of text: String, grammar: SQLLexicalGrammar) -> String {
        let trimmed = StatementBlank.trimming(text)
        let statements = executableStatements(in: trimmed, grammar: grammar)
        guard let first = statements.first, let last = statements.last else { return "" }
        let span = NSRange(location: first.range.location, length: last.range.upperBound - first.range.location)
        return (trimmed as NSString).substring(with: span)
    }

    /// The text the driver receives for `located`, or nil when nothing but a separator is left.
    ///
    /// A `;` that belongs to the statement stays, but only when there is something before it: a unit reduced to its
    /// terminator is as empty as any other.
    ///
    /// A client delimiter never reaches the server, and a `COPY ... FROM STDIN` carries its rows apart from its text,
    /// in ``ExecutableStatement/copyData``.
    public static func executableStatement(from located: LocatedStatement) -> ExecutableStatement? {
        guard !located.isClientLine else { return nil }
        let rawSQL = located.sql
        var content = StatementBlank.trimming(rawSQL[..<sentEnd(of: located)])
        if content.last == ";", located.delimiterLength == 0 {
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
            acceptsBindParameters: located.acceptsBindParameters,
            segmentEnd: NSMaxRange(located.range),
            clientDelimiter: located.clientDelimiter,
            copyData: copyData(of: located)
        )
    }

    private static func copyData(of located: LocatedStatement) -> String? {
        guard let rows = located.copyRows else { return nil }
        let text = located.sql as NSString
        let local = NSRange(location: rows.location - located.offset, length: rows.length)
        return text.substring(with: SQLPsqlScript.copyData(inRows: local, of: text))
    }

    /// The statements after `ran`, one of those `sql` was split into, split again under `grammar`, up to `end`: once
    /// a statement changes how the session reads literals, the rest no longer splits as planned. The split starts at
    /// ``ExecutableStatement/segmentEnd``, so a `COPY`'s rows are never read as statements, and keeps the client
    /// delimiter in force there.
    public static func executableStatements(
        in sql: String,
        after ran: ExecutableStatement,
        through end: Int,
        grammar: SQLLexicalGrammar
    ) -> [ExecutableStatement] {
        let text = sql as NSString
        let limit = min(end, text.length)
        guard ran.segmentEnd < limit else { return [] }
        let resume = Checkpoint(
            offset: ran.segmentEnd,
            decidedThrough: ran.segmentEnd,
            endedStatement: nil,
            delimiter: ran.clientDelimiter
        )
        var results: [ExecutableStatement] = []
        scan(sql: text.substring(to: limit), cursorPosition: nil, grammar: grammar, resumingAt: resume) { located in
            if located.hasContent, let statement = executableStatement(from: located) {
                results.append(statement)
            }
            return true
        }
        return results
    }

    private static func sentEnd(of located: LocatedStatement) -> String.Index {
        let length = located.sql.utf16.count
        let end = located.copyRows.map { $0.location - located.offset } ?? length - located.delimiterLength
        return String.Index(utf16Offset: min(max(0, end), length), in: located.sql)
    }

    /// Whether the text ends inside a block it opened, so the last statement swallowed everything after its opener.
    /// An engine that reads that opener as a name runs the rest as statements of their own.
    public static func endsInsideOpenBlock(_ sql: String, grammar: SQLLexicalGrammar) -> Bool {
        var holdsOpenBlock = false
        scan(sql: sql, cursorPosition: nil, grammar: grammar, onFinish: { holdsOpenBlock = $0 }) { _ in true }
        return holdsOpenBlock
    }

    /// Returns statements preserving trailing semicolons, for display/history/favorites.
    public static func allStatementsPreservingSemicolons(in sql: String, grammar: SQLLexicalGrammar) -> [String] {
        var results: [String] = []
        scan(sql: sql, cursorPosition: nil, grammar: grammar) { statement in
            guard statement.hasContent else { return true }
            let trimmed = StatementBlank.trimming(String(statement.sql[..<sentEnd(of: statement)]))
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

    // MARK: - Resuming

    // The span of a statement that had content, kept without its text so a checkpoint stays small.
    struct EndedStatement: Sendable, Equatable {
        let range: NSRange
        let terminator: SQLStatementTerminator
        let acceptsBindParameters: Bool
        let delimiterLength: Int
        let copyRows: NSRange?
        let clientDelimiter: SQLClientDelimiter?

        func located(in text: NSString) -> LocatedStatement {
            LocatedStatement(
                sql: text.substring(with: range),
                offset: range.location,
                hasContent: true,
                terminator: terminator,
                acceptsBindParameters: acceptsBindParameters,
                delimiterLength: delimiterLength,
                copyRows: copyRows,
                clientDelimiter: clientDelimiter
            )
        }
    }

    // A point where the scan holds no state but the last statement with content and the client delimiter in force,
    // so it can start again there.
    struct Checkpoint: Sendable, Equatable {
        let offset: Int
        // The last offset whose text decided this boundary: an edit there or earlier moves it.
        let decidedThrough: Int
        let endedStatement: EndedStatement?
        var delimiter: SQLClientDelimiter?
    }

    // MARK: - Scanning

    // Segments tile the document: each runs from the end of the previous one to its terminator, whitespace included.
    // With a cursor only the segment holding it is reported, or the last one when it sits past every terminator.
    // See ``SQLStatementScan`` for where a segment ends.
    static func scan(
        sql: String,
        cursorPosition: Int?,
        grammar: SQLLexicalGrammar,
        resumingAt resume: Checkpoint? = nil,
        onCheckpoint: @escaping (Checkpoint) -> Void = { _ in },
        onBatchSeparator: @escaping (SQLBatchSeparator) -> Void = { _ in },
        onScriptText: @escaping (NSRange) -> Void = { _ in },
        onFinish: (_ holdsOpenBlock: Bool) -> Void = { _ in },
        onStatement: @escaping (LocatedStatement) -> Bool
    ) {
        let text = sql as NSString
        guard text.length > 0 else { return }
        var scan = SQLStatementScan(
            text: text,
            cursorPosition: cursorPosition,
            grammar: grammar,
            resume: resume,
            events: SQLStatementScan.Events(
                checkpoint: onCheckpoint,
                batchSeparator: onBatchSeparator,
                scriptText: onScriptText,
                statement: onStatement
            )
        )
        guard scan.run() else { return }
        onFinish(scan.holdsOpenBlock)
    }

    /// Whether the `/` at `offset` stands alone on its line, which is what makes it SQL*Plus's terminator rather than
    /// a division.
    public static func isSlashLine(_ text: NSString, at offset: Int, length: Int) -> Bool {
        var before = offset - 1
        while before >= 0, isLineBlank(text.character(at: before)) {
            before -= 1
        }
        guard before < 0 || text.character(at: before) == SqlLexer.newline else { return false }
        let after = endOfSlashLine(text, at: offset, length: length)
        return after == length || text.character(at: after) == SqlLexer.newline
    }

    // The last offset `isSlashLine` reads after the slash: its line break, or the end of the text.
    static func endOfSlashLine(_ text: NSString, at offset: Int, length: Int) -> Int {
        var after = offset + 1
        while after < length, isLineBlank(text.character(at: after)) {
            after += 1
        }
        return after
    }

    private static func isLineBlank(_ character: UInt16) -> Bool {
        character == SqlLexer.space || character == SqlLexer.tab || character == SqlLexer.carriageReturn
    }
}
