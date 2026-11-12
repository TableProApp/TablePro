import Foundation

/// One pass of ``SQLStatementScanner`` over a text.
///
/// Where a statement ends is the tracker's decision, except at a `GO` line, which ends the batch whatever the tracker
/// thinks and is a segment of its own that runs nothing, and at a client delimiter, which ends the statement wherever
/// it stands in code. A `DELIMITER` line and a psql `\restrict` line are segments that run nothing, and a
/// `COPY ... FROM STDIN` runs on through the rows after it.
///
/// A custom delimiter does not stop a `;` from ending a statement where the tracker says it does: the server still
/// splits the text it gets there, so reading it as one statement would let a gate miss the second.
struct SQLStatementScan {
    struct Events {
        let checkpoint: (SQLStatementScanner.Checkpoint) -> Void
        let batchSeparator: (SQLBatchSeparator) -> Void
        let scriptText: (NSRange) -> Void
        let statement: (SQLStatementScanner.LocatedStatement) -> Bool
    }

    private enum Step {
        case declined
        case consumed
        case finished
    }

    private let text: NSString
    private let length: Int
    private let grammar: SQLLexicalGrammar
    private let cursor: Int?
    private let events: Events

    private var tracker: any SQLStatementBoundaryTracking
    private var currentStart: Int
    private var index: Int
    private var hasStatementContent = false
    private var lastEndedStatement: SQLStatementScanner.EndedStatement?
    private var delimiter: SQLClientDelimiter?

    // Where a `;` ended the statement while the tracker could still take it back at the next token, and the further
    // `;`s after it, which T-SQL also reads as part of an `IF`'s body before its `ELSE`.
    private var heldEnd: Int?
    private var heldSemicolons: [Int] = []

    private static let smallD = UInt16(UnicodeScalar("d").value)

    init(
        text: NSString,
        cursorPosition: Int?,
        grammar: SQLLexicalGrammar,
        resume: SQLStatementScanner.Checkpoint?,
        events: Events
    ) {
        self.text = text
        self.length = text.length
        self.grammar = grammar
        self.cursor = cursorPosition.map { min(max(0, $0), text.length) }
        self.events = events
        self.tracker = SQLStatementBoundaries.makeTracker(for: grammar)
        self.currentStart = min(max(0, resume?.offset ?? 0), text.length)
        self.index = currentStart
        self.lastEndedStatement = resume?.endedStatement
        self.delimiter = resume?.delimiter
    }

    var holdsOpenBlock: Bool {
        tracker.holdsOpenBlock
    }

    /// Returns false when the scan stopped early, because the cursor's segment was found or a reader asked to stop.
    mutating func run() -> Bool {
        while index < length {
            let unit = text.character(at: index)
            var step = readClientLine(unit)
            if step == .declined { step = readDelimiter(unit) }
            if step == .declined { step = readNonCode(unit) }
            if step == .declined { step = readBatchSeparator(unit) }
            if step == .declined { step = readWord(unit) }
            if step == .declined { step = readSemicolon(unit) }
            if step == .declined { step = readSlashLine(unit) }
            switch step {
            case .finished:
                return false
            case .consumed:
                continue
            case .declined:
                guard readBlankOrSymbol(unit) else { return false }
            }
        }
        guard settleHeldEnd(word: nil, decidedThrough: length) else { return false }
        if currentStart < length {
            _ = events.statement(SQLStatementScanner.LocatedStatement(
                sql: text.substring(with: NSRange(location: currentStart, length: length - currentStart)),
                offset: currentStart,
                hasContent: hasStatementContent,
                terminator: tracker.terminator,
                acceptsBindParameters: tracker.acceptsBindParameters,
                clientDelimiter: delimiter
            ))
        }
        return true
    }

    // MARK: - Tokens

    private mutating func readClientLine(_ unit: UInt16) -> Step {
        guard !hasStatementContent else { return .declined }
        if grammar.contains(.delimiterDirective), unit | 0x20 == Self.smallD,
           let directive = SQLDelimiterDirective.line(at: index, in: text, length: length) {
            if let set = directive.delimiter {
                delimiter = SQLClientDelimiter(set)
            }
            return finishClientLine(at: NSMaxRange(directive.range))
        }
        if grammar.contains(.psqlScripts), unit == SqlLexer.backslash,
           let line = SQLPsqlScript.restrictLine(at: index, in: text, length: length) {
            events.scriptText(line)
            return finishClientLine(at: NSMaxRange(line))
        }
        return .declined
    }

    private mutating func readDelimiter(_ unit: UInt16) -> Step {
        guard let delimiter, delimiter.starts(in: text, at: index, length: length) else { return .declined }
        guard settleHeldEnd(word: nil, decidedThrough: index) else { return .finished }
        let end = index + delimiter.units.count
        guard finishSegment(at: end, hasContent: hasStatementContent, delimiterLength: delimiter.units.count) else {
            return .finished
        }
        endStatement(at: end, decidedThrough: end - 1)
        return .consumed
    }

    private mutating func readNonCode(_ unit: UInt16) -> Step {
        guard let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) else { return .declined }
        if !span.kind.isComment {
            guard settleHeldEnd(word: nil, decidedThrough: index) else { return .finished }
        }
        switch span.kind {
        case .lineComment, .blockComment:
            tracker.observeGap()
        case .executableComment:
            hasStatementContent = true
        case .quoted:
            hasStatementContent = true
            tracker.observeQuotedToken(opener: text.character(at: span.start))
        case .parameter:
            hasStatementContent = true
            tracker.observeOpaqueToken()
        }
        index = max(span.end, index + 1)
        return .consumed
    }

    private mutating func readBatchSeparator(_ unit: UInt16) -> Step {
        guard grammar.contains(.batchSeparatorLines),
              let separator = SQLBatchSeparator.line(at: index, in: text, length: length, grammar: grammar)
        else {
            return .declined
        }
        guard settleHeldEnd(word: nil, decidedThrough: index) else { return .finished }
        events.batchSeparator(separator)
        if hasStatementContent {
            guard finishSegment(at: index, hasContent: true) else { return .finished }
        }
        let separatorEnd = NSMaxRange(separator.range)
        guard finishSegment(at: separatorEnd, hasContent: false, standsForEndedStatement: true) else {
            return .finished
        }
        lastEndedStatement = nil
        endStatement(at: separatorEnd, decidedThrough: separatorEnd)
        return .consumed
    }

    private mutating func readWord(_ unit: UInt16) -> Step {
        guard SqlBlockStructure.startsWord(text, at: index, length: length, grammar: grammar) else { return .declined }
        guard heldEnd != nil || tracker.needsWords else {
            hasStatementContent = true
            index += 1
            while index < length, SqlBlockStructure.continuesWord(text.character(at: index), grammar: grammar),
                  delimiter?.starts(in: text, at: index, length: length) != true {
                index += 1
            }
            return .consumed
        }
        let read = SqlBlockStructure.readKeyword(text, at: index, length: length, grammar: grammar)
        let word = delimiter?.cut(read, readAt: index, in: text, length: length) ?? read
        guard settleHeldEnd(word: word.text, decidedThrough: word.end) else { return .finished }
        hasStatementContent = true
        if tracker.needsWords {
            tracker.observeWord(word.text)
        }
        index = word.end
        return .consumed
    }

    private mutating func readSemicolon(_ unit: UInt16) -> Step {
        guard unit == SqlLexer.semicolon else { return .declined }
        if heldEnd != nil {
            _ = tracker.observeSemicolon()
            heldSemicolons.append(index)
            index += 1
            return .consumed
        }
        guard tracker.observeSemicolon() else {
            hasStatementContent = true
            index += 1
            return .consumed
        }
        if tracker.awaitsContinuation {
            heldEnd = index + 1
            index += 1
            return .consumed
        }
        if tracker.copiesFromStandardInput {
            let rows = SQLPsqlScript.copyRows(afterSemicolonAt: index, in: text, length: length)
            let end = NSMaxRange(rows)
            let segment = NSRange(location: currentStart, length: end - currentStart)
            // The rows run to `end` as written: a last row's trailing tab is a column.
            let start = currentStart + StatementBlank.contentRange(of: text.substring(with: segment)).location
            events.scriptText(NSRange(location: start, length: end - start))
            guard finishSegment(at: end, hasContent: hasStatementContent, copyRows: rows) else { return .finished }
            endStatement(at: end, decidedThrough: end + 1)
            return .consumed
        }
        guard finishSegment(at: index + 1, hasContent: hasStatementContent) else { return .finished }
        // A delimiter such as `;;` was looked for past this `;` before the `;` alone was read.
        endStatement(at: index + 1, decidedThrough: index + max(0, (delimiter?.units.count ?? 1) - 1))
        return .consumed
    }

    private mutating func readSlashLine(_ unit: UInt16) -> Step {
        guard grammar.contains(.slashLineTerminators), unit == SqlLexer.slash,
              SQLStatementScanner.isSlashLine(text, at: index, length: length)
        else {
            return .declined
        }
        guard settleHeldEnd(word: nil, decidedThrough: index) else { return .finished }
        if hasStatementContent {
            guard finishSegment(at: index, hasContent: true) else { return .finished }
        }
        guard finishSegment(at: index + 1, hasContent: false, standsForEndedStatement: true) else { return .finished }
        endStatement(
            at: index + 1,
            decidedThrough: SQLStatementScanner.endOfSlashLine(text, at: index, length: length)
        )
        return .consumed
    }

    /// Returns false when the scan is over.
    private mutating func readBlankOrSymbol(_ unit: UInt16) -> Bool {
        let blankLength = StatementBlank.blankLength(in: text, at: index)
        if blankLength > 0 {
            tracker.observeGap()
            index += blankLength
            return true
        }
        guard settleHeldEnd(word: nil, decidedThrough: index) else { return false }
        hasStatementContent = true
        tracker.observeSymbol(unit)
        index += 1
        return true
    }

    // MARK: - Segments

    // A caret on a SQL*Plus `/` line stands for the statement the slash ends, where `Cmd+Enter` is expected to act.
    // A caret on a `GO` line stands for the last statement of its batch, and for nothing when the batch is empty.
    // Returns false once the scan has reported what it was asked for.
    private mutating func finishSegment(
        at end: Int,
        hasContent: Bool,
        standsForEndedStatement: Bool = false,
        delimiterLength: Int = 0,
        copyRows: NSRange? = nil,
        isClientLine: Bool = false
    ) -> Bool {
        let range = NSRange(location: currentStart, length: end - currentStart)
        if hasContent {
            lastEndedStatement = SQLStatementScanner.EndedStatement(
                range: range,
                terminator: tracker.terminator,
                acceptsBindParameters: tracker.acceptsBindParameters,
                delimiterLength: delimiterLength,
                copyRows: copyRows,
                clientDelimiter: delimiter
            )
        }
        if let cursor {
            guard cursor >= currentStart, cursor <= end else {
                currentStart = end
                return true
            }
            if standsForEndedStatement, let ended = lastEndedStatement {
                _ = events.statement(ended.located(in: text))
                return false
            }
        }
        let statement = SQLStatementScanner.LocatedStatement(
            sql: text.substring(with: range),
            offset: currentStart,
            hasContent: hasContent,
            terminator: tracker.terminator,
            acceptsBindParameters: tracker.acceptsBindParameters,
            delimiterLength: delimiterLength,
            copyRows: copyRows,
            clientDelimiter: delimiter,
            isClientLine: isClientLine
        )
        if cursor != nil {
            _ = events.statement(statement)
            return false
        }
        currentStart = end
        return events.statement(statement)
    }

    private mutating func endStatement(at end: Int, decidedThrough: Int) {
        tracker.reset()
        hasStatementContent = false
        checkpoint(at: end, decidedThrough: decidedThrough)
        index = end
    }

    private func checkpoint(at offset: Int, decidedThrough: Int) {
        events.checkpoint(SQLStatementScanner.Checkpoint(
            offset: offset,
            decidedThrough: decidedThrough,
            endedStatement: lastEndedStatement,
            delimiter: delimiter
        ))
    }

    // A `DELIMITER` or `\restrict` line ends a segment that runs nothing.
    private mutating func finishClientLine(at end: Int) -> Step {
        guard finishSegment(at: end, hasContent: false, isClientLine: true) else { return .finished }
        endStatement(at: end, decidedThrough: end)
        return .consumed
    }

    // Settles a held end at the first token after it; returns false once the scan has reported its statement.
    private mutating func settleHeldEnd(word: String?, decidedThrough: Int) -> Bool {
        guard let end = heldEnd else { return true }
        heldEnd = nil
        let semicolons = heldSemicolons
        heldSemicolons.removeAll()
        if tracker.continuesStatement(with: word) { return true }
        guard finishSegment(at: end, hasContent: hasStatementContent) else { return false }
        tracker.reset()
        hasStatementContent = false
        checkpoint(at: end, decidedThrough: decidedThrough)
        for semicolon in semicolons {
            guard finishSegment(at: semicolon + 1, hasContent: false) else { return false }
            checkpoint(at: semicolon + 1, decidedThrough: decidedThrough)
        }
        return true
    }
}
