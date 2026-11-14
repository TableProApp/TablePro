//
//  SQLFileParser.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar
import TableProUtilities

/// A file the import refuses before it sends the statement that needs what it cannot give.
enum SQLFileParseError: LocalizedError, Equatable {
    case copyFromStandardInput(line: Int)
    case spanTooLong(line: Int)

    var errorDescription: String? {
        switch self {
        case .copyFromStandardInput(let line):
            return String(
                format: String(
                    localized: "Line %lld runs COPY FROM STDIN, and this connection cannot load its rows. Run the file with psql, or dump it again with --inserts."
                ),
                line
            )
        case .spanTooLong(let line):
            return String(
                format: String(localized: "The string or comment that starts on line %lld is longer than the import reads."),
                line
            )
        }
    }
}

final class SQLFileParser: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLFileParser")

    /// SQL Server takes at most 65,536 packets of 4,096 bytes in one request, about 134 million UTF-16 units of batch
    /// text: measured on Azure SQL Edge 15, a 133,900,000-unit batch ran and a 133,960,000-unit one closed the
    /// connection. A batch that reaches half of that ends at its next `;`, which leaves the statement it ends inside
    /// as much room again. A script whose `GO` lines stand that far apart is then sent in pieces the server takes,
    /// and held one piece at a time rather than whole.
    static let defaultBatchCutLength = 67_108_864

    private let limits: ReadLimits

    // As much as the core's script reader holds of one statement: a string or comment longer is not one a server takes.
    static let defaultSpanLimit = 134_217_728

    init(
        batchCutLength: Int = SQLFileParser.defaultBatchCutLength,
        chunkSize: Int = SQLFileParser.defaultChunkSize,
        copyPieceLength: Int = SQLFileParser.defaultCopyPieceLength,
        spanLimit: Int = SQLFileParser.defaultSpanLimit
    ) {
        limits = ReadLimits(
            batchCutLength: batchCutLength,
            chunkSize: chunkSize,
            copyPieceLength: copyPieceLength,
            spanLimit: spanLimit
        )
    }

    /// One statement the file holds, or on a grammar that cuts scripts into batches, one batch, with how many times
    /// the script runs it.
    struct ParsedStatement {
        let statement: String
        let lineNumber: Int
        let repeatCount: Int
        var readsCopyRows = false
    }

    enum ParserState {
        case normal
        /// A psql `\restrict` line, which runs to its line feed whatever ends a comment.
        case inClientLine
    }

    // Units already read that stay in the buffer: whether `E'` or `$` opens a literal depends on the unit before it.
    static let lookBehind = 256

    private static let kSemicolon: unichar = 0x3B
    static let kNewline: unichar = 0x0A
    private static let kSlash: unichar = 0x2F
    private static let kBackslash: unichar = 0x5C
    private static let kSpace: unichar = 0x20
    private static let kTab: unichar = 0x09
    private static let kCarriageReturn: unichar = 0x0D
    private static let kCapitalG: unichar = 0x47
    private static let kSmallG: unichar = 0x67

    // A client delimiter is matched whole, so its first unit waits until the buffer holds as many units as it has.
    nonisolated private static func needsLookahead(
        _ char: unichar,
        available: Int,
        state: ParserState,
        delimiter: NSString,
        isSingleCharDelimiter: Bool
    ) -> Bool {
        state == .normal && !isSingleCharDelimiter && available < delimiter.length && char == delimiter.character(at: 0)
    }

    nonisolated private static func isWhitespace(_ char: unichar) -> Bool {
        char == kSpace || char == kTab || char == kNewline || char == kCarriageReturn
    }

    private static func markContent(
        _ hasContent: Bool, _ startLine: Int, _ currentLine: Int
    ) -> (Bool, Int) {
        hasContent ? (true, startLine) : (true, currentLine)
    }

    private static func appendChar(_ char: unichar, to string: NSMutableString?) {
        guard let string else { return }
        var c = char
        CFStringAppendCharacters(string as CFMutableString, &c, 1)
    }

    private static func matchesDelimiter(
        at position: Int, delimiter: NSString, in buffer: NSString, bufLen: Int
    ) -> Bool {
        let delimLen = delimiter.length
        guard position + delimLen <= bufLen else { return false }
        for j in 0..<delimLen where buffer.character(at: position + j) != delimiter.character(at: j) {
            return false
        }
        return true
    }

    // mysqldump writes `DELIMITER ;;`, so a `;` on the directive's line ends nothing.
    private static func readsDelimiterDirective(_ ctx: ParserContext) -> Bool {
        guard ctx.grammar.contains(.delimiterDirective), ctx.statementOpensLine,
              let statement = ctx.currentStatement
        else { return false }
        let length = statement.length
        var index = 0
        while index < length, isWhitespace(statement.character(at: index)) {
            index += 1
        }
        guard SQLDelimiterDirective.startsLine(in: statement, at: index, length: length) else { return false }
        let rest = NSRange(location: index, length: length - index)
        return statement.range(of: "\n", options: [], range: rest).location == NSNotFound
    }

    /// The `DELIMITER` line the statement read so far is, where it opened its line as the mysql client requires.
    private static func delimiterDirective(_ ctx: ParserContext) -> SQLDelimiterDirective? {
        guard ctx.grammar.contains(.delimiterDirective), ctx.statementOpensLine,
              let statement = ctx.currentStatement
        else { return nil }
        let length = statement.length
        var start = 0
        while start < length, isWhitespace(statement.character(at: start)) {
            start += 1
        }
        let rest = NSRange(location: start, length: length - start)
        guard statement.range(of: "\n", options: [], range: rest).location == NSNotFound else { return nil }
        return SQLDelimiterDirective.line(startingAt: start, in: statement, length: length)
    }

    struct ParserContext {
        var grammar: SQLLexicalGrammar
        var state: ParserState = .normal
        let currentStatement: NSMutableString?
        var hasStatementContent = false
        var currentLine = 1
        var statementStartLine = 1
        var currentDelimiter: NSString = ";" as NSString
        var isSingleCharDelimiter = true
        var collected: [ParsedStatement] = []

        // The next read takes as much again, so a literal of many megabytes is lexed a few times, not once per chunk.
        var heldSpanLength = 0

        /// SQL Server's tools read a script the way sqlcmd does: a line holding only `GO` ends a batch, the batch goes
        /// to the server whole with its `;` and its comments, and the `GO` line goes nowhere. The comments stay so the
        /// server's line numbers count the file's lines and a routine keeps the comments written inside it.
        ///
        /// Only a file that holds a `GO` line is read so. One that holds none was written to run a statement at a
        /// time, cut at each `;`: that is how every SQL Server dump TablePro wrote before it wrote `GO` lines reads,
        /// and read as one batch it fails on its first view with Msg 111, having run none of it.
        let readsBatches: Bool
        let batchCutLength: Int

        /// Set once a `GO` line has ended a batch, which is what settles whether a file is read in batches.
        var sawBatchSeparator = false

        /// Whether only spaces and tabs stand between the last line break and the unit being read, which is where a
        /// `GO` line can start. Tracked here because the buffer no longer holds the line's start once a chunk is
        /// consumed.
        var lineHoldsOnlyBlanks = true

        /// How much of the line after a `G` held back for the rest of its line is already known to hold no line break,
        /// so a long line is searched once rather than once per chunk.
        var separatorLineSearched = 0

        /// The line the batch text starts on before its leading whitespace, and how many units were read before it.
        var batchTextStartLine = 1
        var batchStartUnit = 0
        var unitsBeforeBuffer = 0

        /// The statement grammar, for a dialect whose statement can own a `;`: a PL/SQL unit arrives whole with
        /// its own `;`, and so do a T-SQL `MERGE` and a `BEGIN...END` routine body, and a CQL batch arrives whole
        /// with every `;` inside it. A batch keeps every `;` it holds, so a file read in batches needs none. Every
        /// other dialect has always split an import at each `;` and relies on `DELIMITER` or dollar quoting for a
        /// routine body, and keeps doing so.
        var boundaries: (any SQLStatementBoundaryTracking)?

        /// A `;` that ended the statement while the tracker could still take it back at the next token.
        var heldEnd: HeldEnd?
        var word: [unichar] = []
        /// Where the word being read starts in the statement text, and on which line.
        var wordStart = 0
        var wordStartLine = 1
        var lineHasCode = false
        /// Whether the statement's first unit was the first code on its line, where a `DELIMITER` can stand.
        var statementOpensLine = false
        var pendingSlashLine = false
        var pendingSlashTrailing: [unichar] = []

        /// Whether the unit before the one being read belongs to a word or a name, which a letter glued to it continues. A number is neither,
        /// so `1MERGE` is a number and a keyword, as the statement scanner and SQL Server both read it.
        var previousUnitInWord = false

        /// Set for the last pass over the buffer, once the file has nothing more to give. A character held back for
        /// the one after it is settled with nothing after it, instead of being left in the buffer and dropped.
        var atEndOfInput = false

        init(grammar: SQLLexicalGrammar, currentStatement: NSMutableString?, batchCutLength: Int, readsBatches: Bool) {
            self.grammar = grammar
            self.currentStatement = currentStatement
            self.readsBatches = readsBatches
            self.batchCutLength = batchCutLength
            self.boundaries = !readsBatches && Self.readsStatementsWithTracker(grammar)
                ? SQLStatementBoundaries.makeTracker(for: grammar)
                : nil
        }

        // Only between statements, where nothing of the next one has been lexed yet.
        mutating func adopt(_ next: SQLLexicalGrammar) {
            guard state == .normal, !hasStatementContent, next != grammar else { return }
            grammar = next
            boundaries = !readsBatches && Self.readsStatementsWithTracker(next)
                ? SQLStatementBoundaries.makeTracker(for: next)
                : nil
        }

        // A psql script needs the tracker to find a `COPY ... FROM STDIN`, and it then holds a `BEGIN ATOMIC` body
        // and a rule's action list together as the editor does.
        private static func readsStatementsWithTracker(_ grammar: SQLLexicalGrammar) -> Bool {
            SQLStatementBoundaries.statementsCanOwnSemicolons(in: grammar) || grammar.contains(.psqlScripts)
        }

        // A SQL Server statement is a batch of its own and keeps the comments inside it, not the ones before it.
        var keepsComments: Bool {
            readsBatches || (grammar.contains(.batchSeparatorLines) && hasStatementContent)
        }
    }

    /// The statement's text before the held `;`, and whether the `;` belongs to it.
    struct HeldEnd {
        let textLength: Int
        let keepsSemicolon: Bool
    }

    /// Settles a held end at the first token after it, `word` being that token when it is a word. When the `;` ended
    /// the statement, the text up to it is yielded and the word, if any, starts the next statement.
    private static func settleHeldEnd(_ ctx: inout ParserContext, word: String?) {
        guard let held = ctx.heldEnd else { return }
        ctx.heldEnd = nil
        guard ctx.boundaries?.continuesStatement(with: word) != true else { return }
        var next = ""
        if let statement = ctx.currentStatement {
            if word != nil, ctx.wordStart < statement.length {
                next = statement.substring(from: ctx.wordStart)
            }
            let kept = held.textLength + (held.keepsSemicolon ? 1 : 0)
            statement.deleteCharacters(in: NSRange(location: kept, length: statement.length - kept))
        }
        yieldAndReset(&ctx)
        guard word != nil else { return }
        ctx.currentStatement?.setString(next)
        ctx.hasStatementContent = true
        ctx.statementStartLine = ctx.wordStartLine
    }

    private static func trimmedStatement(_ ctx: ParserContext) -> String {
        (ctx.currentStatement as NSString?)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func resetStatement(_ ctx: inout ParserContext) {
        ctx.currentStatement?.setString("")
        ctx.hasStatementContent = false
        ctx.boundaries?.reset()
        ctx.heldEnd = nil
        ctx.statementOpensLine = false
        ctx.word.removeAll(keepingCapacity: true)
    }

    private static func isLineBlank(_ char: unichar) -> Bool {
        char == kSpace || char == kTab || char == kCarriageReturn
    }

    /// Hands the word that just ended to the tracker. A word is only assembled while the tracker still reads words,
    /// so a statement it has already classified as plain SQL costs nothing per character.
    private static func flushWord(_ ctx: inout ParserContext) {
        guard !ctx.word.isEmpty else { return }
        let word = String(utf16CodeUnits: ctx.word, count: ctx.word.count).uppercased()
        ctx.word.removeAll(keepingCapacity: true)
        settleHeldEnd(&ctx, word: word)
        ctx.boundaries?.observeWord(word)
    }

    private static func observeWordCharacter(
        _ ctx: inout ParserContext,
        char: unichar,
        i: Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> Bool {
        guard ctx.boundaries != nil else { return false }
        let followsWord = ctx.previousUnitInWord
        ctx.previousUnitInWord = (followsWord && SqlBlockStructure.continuesWord(char, grammar: ctx.grammar))
            || (char >= 0x80 && SQLNonCodeSpan.isWordUnit(char))
        if !ctx.word.isEmpty {
            if SqlBlockStructure.continuesWord(char, grammar: ctx.grammar) {
                ctx.word.append(char)
                return true
            }
            flushWord(&ctx)
        }
        guard SqlBlockStructure.startsWord(nsBuffer, at: i, length: bufLen, grammar: ctx.grammar), !followsWord else {
            return false
        }
        ctx.previousUnitInWord = true
        if ctx.heldEnd != nil || ctx.boundaries?.needsWords == true {
            ctx.wordStart = ctx.currentStatement?.length ?? 0
            ctx.wordStartLine = ctx.currentLine
            ctx.word.append(char)
        }
        return true
    }

    /// Settles a `/` held back at the start of a line once the line's end shows whether it stood alone.
    ///
    /// Returns true when `char` was consumed as trailing whitespace on the `/` line.
    private static func settlePendingSlashLine(_ ctx: inout ParserContext, char: unichar) -> Bool {
        guard ctx.pendingSlashLine else { return false }
        if isLineBlank(char) {
            ctx.pendingSlashTrailing.append(char)
            return true
        }
        ctx.pendingSlashLine = false
        if char == kNewline {
            ctx.pendingSlashTrailing.removeAll()
            yieldAndReset(&ctx)
            return false
        }
        (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
            ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
        appendChar(kSlash, to: ctx.currentStatement)
        for trailing in ctx.pendingSlashTrailing {
            appendChar(trailing, to: ctx.currentStatement)
        }
        ctx.pendingSlashTrailing.removeAll()
        ctx.boundaries?.observeSymbol(kSlash)
        return false
    }

    // A refused argument leaves the delimiter as it was, and the line still runs nothing.
    private static func processDelimiterChange(_ ctx: inout ParserContext, char: unichar) {
        guard char == kNewline, ctx.hasStatementContent, let directive = delimiterDirective(ctx) else { return }
        if let newDelim = directive.delimiter {
            ctx.currentDelimiter = newDelim as NSString
            ctx.isSingleCharDelimiter = ctx.currentDelimiter.length == 1
                && ctx.currentDelimiter.character(at: 0) == kSemicolon
        }
        resetStatement(&ctx)
    }

    // pg_dump's `\restrict` and `\unrestrict` limit psql's meta-commands, and none runs here, so the line is read as a
    // comment.
    private static func skipRestrictLine(
        _ ctx: inout ParserContext,
        at i: Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult? {
        guard ctx.grammar.contains(.psqlScripts), !ctx.hasStatementContent, !ctx.lineHasCode else { return nil }
        if i + SQLPsqlScript.restrictLineLookahead > bufLen, !ctx.atEndOfInput {
            return StepResult(advanced: false, deferred: true)
        }
        guard SQLPsqlScript.startsRestrictLine(in: nsBuffer, at: i, length: bufLen) else { return nil }
        ctx.state = .inClientLine
        ctx.boundaries?.observeGap()
        return StepResult(advanced: false, deferred: false)
    }

    struct StepResult {
        var advanced: Bool
        var deferred: Bool
    }

    private static func processNormalChar(
        _ ctx: inout ParserContext,
        char: unichar,
        i: inout Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult {
        if settlePendingSlashLine(&ctx, char: char) {
            return StepResult(advanced: false, deferred: false)
        }

        if ctx.readsBatches, ctx.lineHoldsOnlyBlanks, char == kCapitalG || char == kSmallG,
           let step = endBatchAtSeparatorLine(&ctx, i: &i, nsBuffer: nsBuffer, bufLen: bufLen) {
            return step
        }

        if char == kBackslash, let step = skipRestrictLine(&ctx, at: i, nsBuffer: nsBuffer, bufLen: bufLen) {
            return step
        }

        // The mysql client looks for its delimiter before it looks for a comment, as the statement scanner does.
        if !ctx.isSingleCharDelimiter, !readsDelimiterDirective(ctx),
           matchesDelimiter(at: i, delimiter: ctx.currentDelimiter, in: nsBuffer, bufLen: bufLen) {
            yieldAndReset(&ctx)
            i += ctx.currentDelimiter.length
            return StepResult(advanced: true, deferred: false)
        }

        if SQLNonCodeSpan.mayStart(char), let step = readSpan(&ctx, at: &i, nsBuffer: nsBuffer, bufLen: bufLen) {
            return step
        }

        if observeWordCharacter(&ctx, char: char, i: i, nsBuffer: nsBuffer, bufLen: bufLen) {
            if !ctx.hasStatementContent {
                ctx.statementOpensLine = !ctx.lineHasCode
            }
            (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
                ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
            appendChar(char, to: ctx.currentStatement)
            return StepResult(advanced: false, deferred: false)
        }

        processDelimiterChange(&ctx, char: char)

        if ctx.isSingleCharDelimiter && char == kSemicolon {
            processSemicolon(&ctx, at: i)
            return StepResult(advanced: false, deferred: false)
        }

        if ctx.grammar.contains(.slashLineTerminators) && char == kSlash && !ctx.lineHasCode {
            ctx.pendingSlashLine = true
            return StepResult(advanced: false, deferred: false)
        }

        appendPlainUnit(&ctx, char: char)
        return StepResult(advanced: false, deferred: false)
    }

    private static func readSpan(
        _ ctx: inout ParserContext,
        at i: inout Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult? {
        let span = SQLNonCodeSpan.span(at: i, in: nsBuffer, grammar: ctx.grammar)
        if !ctx.atEndOfInput, SQLNonCodeSpan.needsMoreText(span, at: i, in: nsBuffer, grammar: ctx.grammar) {
            ctx.heldSpanLength = bufLen - i
            return StepResult(advanced: false, deferred: true)
        }
        guard let span else { return nil }
        flushWord(&ctx)
        ctx.previousUnitInWord = false
        switch span.kind {
        case .lineComment, .blockComment:
            ctx.boundaries?.observeGap()
            if ctx.keepsComments {
                appendRange(&ctx, from: span.start, to: span.end, in: nsBuffer)
            } else if span.kind == .blockComment {
                // The server reads a comment as a blank, so `a/* x */FROM` must not become `aFROM`.
                appendChar(kSpace, to: ctx.currentStatement)
            }
        case .executableComment, .quoted, .parameter:
            settleHeldEnd(&ctx, word: nil)
            (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
                ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
            appendRange(&ctx, from: span.start, to: span.end, in: nsBuffer)
            if span.kind == .quoted {
                ctx.boundaries?.observeQuotedToken(opener: nsBuffer.character(at: span.start))
            } else if span.kind == .parameter {
                ctx.boundaries?.observeOpaqueToken()
            }
        }
        ctx.currentLine += lineFeeds(in: nsBuffer, from: span.start + 1, to: span.end)
        i = span.end
        return StepResult(advanced: true, deferred: false)
    }

    private static func lineFeeds(in buffer: NSString, from start: Int, to end: Int) -> Int {
        var count = 0
        var index = start
        while index < end {
            if buffer.character(at: index) == kNewline { count += 1 }
            index += 1
        }
        return count
    }

    // Whitespace, or a symbol no rule above claimed.
    private static func appendPlainUnit(_ ctx: inout ParserContext, char: unichar) {
        if isWhitespace(char) {
            ctx.boundaries?.observeGap()
        } else {
            settleHeldEnd(&ctx, word: nil)
            if !ctx.hasStatementContent {
                ctx.statementStartLine = ctx.currentLine
                ctx.hasStatementContent = true
                ctx.statementOpensLine = !ctx.lineHasCode
            }
            ctx.boundaries?.observeSymbol(char)
        }
        appendChar(char, to: ctx.currentStatement)
    }

    /// A `;` ends the statement unless the grammar holds it inside a PL/SQL unit or a routine body, and a statement
    /// that owns the `;` that ends it keeps it. In a batch it ends nothing, unless the batch has grown past what the
    /// server takes in one request.
    private static func processSemicolon(_ ctx: inout ParserContext, at i: Int) {
        if readsDelimiterDirective(ctx) {
            appendChar(kSemicolon, to: ctx.currentStatement)
            return
        }
        if ctx.readsBatches {
            appendChar(kSemicolon, to: ctx.currentStatement)
            let batchEnd = ctx.unitsBeforeBuffer + i + 1
            if batchEnd - ctx.batchStartUnit >= ctx.batchCutLength {
                yieldBatch(&ctx, repeatCount: 1, nextBatchStart: batchEnd)
            }
            return
        }
        guard ctx.boundaries != nil else {
            yieldAndReset(&ctx)
            return
        }
        flushWord(&ctx)
        // T-SQL also reads further `;`s after an `IF`'s body as part of it, up to its `ELSE`.
        if ctx.heldEnd != nil {
            _ = ctx.boundaries?.observeSemicolon()
            appendChar(kSemicolon, to: ctx.currentStatement)
            return
        }
        let endsStatement = ctx.boundaries?.observeSemicolon() ?? true
        guard endsStatement else {
            appendChar(kSemicolon, to: ctx.currentStatement)
            return
        }
        if ctx.boundaries?.copiesFromStandardInput == true {
            ctx.collected.append(ParsedStatement(
                statement: trimmedStatement(ctx), lineNumber: ctx.statementStartLine, repeatCount: 1, readsCopyRows: true
            ))
            resetStatement(&ctx)
            return
        }
        if ctx.boundaries?.awaitsContinuation == true, ctx.hasStatementContent {
            ctx.heldEnd = HeldEnd(
                textLength: ctx.currentStatement?.length ?? 0,
                keepsSemicolon: ctx.boundaries?.terminator == .partOfStatement
            )
            appendChar(kSemicolon, to: ctx.currentStatement)
            return
        }
        if ctx.boundaries?.terminator == .partOfStatement, ctx.hasStatementContent {
            appendChar(kSemicolon, to: ctx.currentStatement)
        }
        yieldAndReset(&ctx)
    }

    private static func yieldAndReset(_ ctx: inout ParserContext) {
        if ctx.hasStatementContent {
            let text = trimmedStatement(ctx)
            ctx.collected.append(ParsedStatement(statement: text, lineNumber: ctx.statementStartLine, repeatCount: 1))
        }
        resetStatement(&ctx)
    }

    /// Ends the batch read so far, which is sent only when it holds code: a batch of comments and blanks runs nothing.
    ///
    /// Its line is the one its text starts on once the leading blanks are trimmed, because that is the line the server
    /// counts as the batch's first.
    private static func yieldBatch(_ ctx: inout ParserContext, repeatCount: Int, nextBatchStart: Int) {
        if ctx.hasStatementContent {
            let lineNumber = ctx.batchTextStartLine + SQLFileBatchLines.leadingLineFeeds(in: ctx.currentStatement)
            ctx.collected.append(
                ParsedStatement(statement: trimmedStatement(ctx), lineNumber: lineNumber, repeatCount: repeatCount)
            )
        }
        resetStatement(&ctx)
        ctx.batchTextStartLine = ctx.currentLine
        ctx.batchStartUnit = nextBatchStart
    }

    /// Ends the batch at the `GO` line starting at `i` and steps over the line, or answers nil when the line is code.
    private static func endBatchAtSeparatorLine(
        _ ctx: inout ParserContext,
        i: inout Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult? {
        switch batchSeparator(&ctx, at: i, nsBuffer: nsBuffer, bufLen: bufLen) {
        case .needsMoreData:
            return StepResult(advanced: false, deferred: true)
        case .separator(let separator):
            let end = NSMaxRange(separator.range)
            ctx.sawBatchSeparator = true
            yieldBatch(&ctx, repeatCount: separator.repeatCount, nextBatchStart: ctx.unitsBeforeBuffer + end)
            i = end
            return StepResult(advanced: true, deferred: false)
        case .code:
            return nil
        }
    }

    private enum BatchSeparatorRead {
        case separator(SQLBatchSeparator)
        case code
        case needsMoreData
    }

    /// Reads the line a `G` starts once the buffer holds all of it: what follows `GO` decides, and a line cut off at
    /// the end of a chunk would read as ending there.
    private static func batchSeparator(
        _ ctx: inout ParserContext,
        at i: Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> BatchSeparatorRead {
        let lineBreak = SQLFileBatchLines.lineBreak(in: nsBuffer, from: i + ctx.separatorLineSearched, length: bufLen)
        guard lineBreak != nil || ctx.atEndOfInput else {
            ctx.separatorLineSearched = bufLen - i
            return .needsMoreData
        }
        ctx.separatorLineSearched = 0
        guard let separator = SQLBatchSeparator.line(startingAt: i, in: nsBuffer, length: bufLen, grammar: ctx.grammar)
        else {
            return .code
        }
        return .separator(separator)
    }

    static func appendRange(
        _ ctx: inout ParserContext,
        from start: Int,
        to end: Int,
        in buffer: NSString
    ) {
        guard let target = ctx.currentStatement, end > start else { return }
        target.append(buffer.substring(with: NSRange(location: start, length: end - start)))
    }

    func parseFile(url: URL, encoding: String.Encoding, grammar: SQLLexicalGrammar) -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        parseFile(url: url, encoding: encoding, grammar: { grammar })
    }

    // Asked before each statement is cut, once the one before it ran: `SET sql_mode` changes how the next is read.
    func parseFile(
        url: URL,
        encoding: String.Encoding,
        grammar: @escaping @Sendable () -> SQLLexicalGrammar,
        onRead: (@Sendable (_ bytesRead: Int64, _ fileSize: Int64) -> Void)? = nil
    ) -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        let session = ParseSession(url: url, encoding: encoding, grammar: grammar, countOnly: false, limits: limits, onRead: onRead)
        return AsyncThrowingStream(unfolding: {
            try await session.nextRun()
        })
    }

    func parseElements(
        url: URL,
        encoding: String.Encoding,
        grammar: SQLLexicalGrammar
    ) -> AsyncThrowingStream<PluginImportElement, Error> {
        parseElements(url: url, encoding: encoding, grammar: { grammar })
    }

    // The statements as parseFile yields them, and each `COPY ... FROM STDIN` with a reader over its rows.
    func parseElements(
        url: URL,
        encoding: String.Encoding,
        grammar: @escaping @Sendable () -> SQLLexicalGrammar,
        onRead: (@Sendable (_ bytesRead: Int64, _ fileSize: Int64) -> Void)? = nil
    ) -> AsyncThrowingStream<PluginImportElement, Error> {
        let session = ParseSession(url: url, encoding: encoding, grammar: grammar, countOnly: false, limits: limits, onRead: onRead)
        return AsyncThrowingStream(unfolding: {
            try await session.nextElement()
        })
    }

    // Runs are added up rather than walked: a `GO n` count can reach `Int32.max`. A COPY counts as one.
    func countStatements(
        url: URL,
        encoding: String.Encoding,
        grammar: SQLLexicalGrammar
    ) async throws -> Int {
        let session = ParseSession(url: url, encoding: encoding, grammar: { grammar }, countOnly: true, limits: limits)
        var count = 0

        while let statement = try await session.nextStatement() {
            try Task.checkCancellation()
            count += statement.repeatCount
        }

        return count
    }
}

extension SQLFileParser {
    /// How a session cuts its file.
    private enum Reading {
        /// Settled from the file before its first statement: in batches when it holds a `GO` line and the grammar
        /// reads them, else a statement at a time.
        case fromFile
        /// At the file's `GO` lines, as sqlcmd cuts a script.
        case batches
    }

    private final class ParseSession: @unchecked Sendable {
        private let url: URL
        private let encoding: String.Encoding
        private let grammar: @Sendable () -> SQLLexicalGrammar
        private let limits: ReadLimits
        private let onRead: (@Sendable (Int64, Int64) -> Void)?

        private var fileHandle: FileHandle?
        private var fileSize: Int64 = 0
        private var bytesRead: Int64 = 0
        private var ctx: ParserContext
        private let nsBuffer = NSMutableString()
        // Text before it is lexed; it is deleted when the next chunk is read, not once per statement.
        private var readOffset = 0
        private var decoder: SQLChunkDecoder
        private var emitIndex = 0
        private var finished = false
        private var readingSettled: Bool
        private var repeating: ParsedStatement?
        private var remainingRuns = 0

        // The rows of the COPY last yielded while any are unread, and which COPY that is, so a reader handed out
        // for an earlier one answers nil.
        private var copyRows: CopyRowsScanner?
        private var copyGeneration = 0
        private var rowsFailure: Error?

        init(
            url: URL,
            encoding: String.Encoding,
            grammar: @escaping @Sendable () -> SQLLexicalGrammar,
            countOnly: Bool,
            limits: ReadLimits,
            reading: Reading = .fromFile,
            onRead: (@Sendable (Int64, Int64) -> Void)? = nil
        ) {
            self.url = url
            self.encoding = encoding
            self.grammar = grammar
            self.limits = limits
            self.onRead = onRead
            self.decoder = SQLChunkDecoder(encoding: encoding)
            self.readingSettled = reading == .batches
            let initialGrammar = grammar()
            // A `DELIMITER` line is read from the statement's text, so a count needs the text too.
            let keepsText = !countOnly || initialGrammar.contains(.delimiterDirective)
            self.ctx = ParserContext(
                grammar: initialGrammar,
                currentStatement: keepsText ? NSMutableString() : nil,
                batchCutLength: limits.batchCutLength,
                readsBatches: reading == .batches
            )
        }

        deinit {
            closeFile()
        }

        func nextRun() async throws -> (statement: String, lineNumber: Int)? {
            let element = try await nextElement()
            // The rows after the `COPY` would otherwise reach the server as statements.
            if case let .copyFromStandardInput(_, line, _)? = element {
                finished = true
                closeFile()
                throw SQLFileParseError.copyFromStandardInput(line: line)
            }
            guard case let .statement(statement, lineNumber)? = element else { return nil }
            return (statement, lineNumber)
        }

        func nextElement() async throws -> PluginImportElement? {
            if let repeating, remainingRuns > 0 {
                remainingRuns -= 1
                return .statement(repeating.statement, lineNumber: repeating.lineNumber)
            }
            guard let next = try await nextStatement() else { return nil }
            guard next.readsCopyRows else {
                repeating = next
                remainingRuns = next.repeatCount - 1
                return .statement(next.statement, lineNumber: next.lineNumber)
            }
            let generation = copyGeneration
            // The driver reads pieces on its own queue while the import awaits the copy, and the import asks for the
            // next element only once the copy returns, so the session is never used from two places at once.
            let rows = PluginCopyData { [self] in try nextRowsPiece(generation: generation) }
            return .copyFromStandardInput(statement: next.statement, lineNumber: next.lineNumber, rows: rows)
        }

        func nextStatement() async throws -> ParsedStatement? {
            if let failure = rowsFailure {
                rowsFailure = nil
                throw failure
            }
            while true {
                if emitIndex < ctx.collected.count {
                    let item = ctx.collected[emitIndex]
                    emitIndex += 1
                    if item.readsCopyRows {
                        copyGeneration += 1
                        copyRows = CopyRowsScanner(pieceLength: limits.copyPieceLength)
                    }
                    return item
                }
                ctx.collected.removeAll(keepingCapacity: true)
                emitIndex = 0

                if finished {
                    return nil
                }

                do {
                    try passUnreadRows()
                    try settleReading()
                    guard !Task.isCancelled else {
                        finished = true
                        closeFile()
                        return nil
                    }
                    ctx.adopt(grammar())
                    try readNextStatement()
                } catch {
                    finished = true
                    closeFile()
                    SQLFileParser.logger.error("SQL file parsing failed: \(error.localizedDescription)")
                    throw error
                }
            }
        }

        // A batch cannot be put back together from statements already sent.
        private func settleReading() throws {
            guard !readingSettled else { return }
            readingSettled = true
            let grammar = ctx.grammar
            guard grammar.contains(.batchSeparatorLines) else { return }
            let scan = ParseSession(
                url: url,
                encoding: encoding,
                grammar: { grammar },
                countOnly: true,
                limits: limits,
                reading: .batches
            )
            guard try scan.findsBatchSeparator() else { return }
            ctx = ParserContext(
                grammar: grammar,
                currentStatement: ctx.currentStatement,
                batchCutLength: limits.batchCutLength,
                readsBatches: true
            )
        }

        func findsBatchSeparator() throws -> Bool {
            defer { closeFile() }
            while !finished, !ctx.sawBatchSeparator, !Task.isCancelled {
                try readNextStatement()
                ctx.collected.removeAll(keepingCapacity: true)
            }
            return ctx.sawBatchSeparator
        }

        // A MySQL count keeps each statement's text, so the cut drains per statement as well as per chunk.
        private func readNextStatement() throws {
            try autoreleasepool {
                processBuffer()
                guard ctx.collected.isEmpty else { return }
                guard !ctx.atEndOfInput else {
                    emitTrailingStatement()
                    finished = true
                    closeFile()
                    return
                }
                let held = ctx.heldSpanLength
                ctx.heldSpanLength = 0
                // A span is held whole until it ends, so one that never ends is refused rather than read into memory.
                guard held <= limits.spanLimit else { throw SQLFileParseError.spanTooLong(line: ctx.currentLine) }
                try readChunk()
                let wanted = min(2 * held, limits.spanLimit + 1)
                while held > 0, !ctx.atEndOfInput, !Task.isCancelled, nsBuffer.length - readOffset < wanted {
                    try readChunk()
                }
            }
        }

        private func readChunk() throws {
            let handle = try openFileIfNeeded()
            // A count, a GO scan and a driver's COPY read chunk after chunk with nothing draining the autorelease pool.
            let rawData = try autoreleasepool { try handle.read(upToCount: limits.chunkSize) } ?? Data()
            if !rawData.isEmpty, let onRead {
                bytesRead += Int64(rawData.count)
                onRead(bytesRead, fileSize)
            }

            if rawData.isEmpty && !decoder.hasPendingBytes {
                ctx.atEndOfInput = true
                return
            }

            let isFinalChunk = rawData.isEmpty
            guard let chunk = decoder.decode(rawData) else {
                throw DecompressionError.fileReadFailed(
                    "Failed to decode file with \(encoding.description) encoding"
                )
            }

            if isFinalChunk && decoder.hasPendingBytes {
                throw DecompressionError.fileReadFailed(
                    "Trailing bytes did not form a valid \(encoding.description) sequence at end of file"
                )
            }

            let consumed = readOffset - min(readOffset, SQLFileParser.lookBehind)
            if consumed > 0 {
                nsBuffer.deleteCharacters(in: NSRange(location: 0, length: consumed))
                ctx.unitsBeforeBuffer += consumed
                readOffset -= consumed
            }
            nsBuffer.append(chunk)
        }

        // Stops after the first statement it ends, so the next is cut with the grammar the session has then.
        private func processBuffer() {
            let bufLen = nsBuffer.length
            var i = readOffset

            while i < bufLen {
                let stepStart = i
                let char = nsBuffer.character(at: i)
                if !ctx.atEndOfInput && SQLFileParser.needsLookahead(
                    char,
                    available: bufLen - i,
                    state: ctx.state,
                    delimiter: ctx.currentDelimiter,
                    isSingleCharDelimiter: ctx.isSingleCharDelimiter
                ) {
                    break
                }

                if char == SQLFileParser.kNewline { ctx.currentLine += 1 }
                let step: StepResult

                switch ctx.state {
                case .normal:
                    step = SQLFileParser.processNormalChar(&ctx, char: char, i: &i, nsBuffer: nsBuffer, bufLen: bufLen)

                case .inClientLine:
                    if char == SQLFileParser.kNewline {
                        ctx.state = .normal
                    }
                    step = StepResult(advanced: false, deferred: false)
                }

                if step.deferred { break }
                if char == SQLFileParser.kNewline {
                    ctx.lineHasCode = false
                } else if !SQLFileParser.isLineBlank(char) && !ctx.pendingSlashLine {
                    ctx.lineHasCode = true
                }
                if !step.advanced { i += 1 }
                if ctx.state != .normal {
                    ctx.previousUnitInWord = false
                }
                if ctx.readsBatches {
                    ctx.lineHoldsOnlyBlanks = SQLFileBatchLines.holdsOnlyBlanks(
                        nsBuffer, from: stepStart, to: min(i, bufLen), before: ctx.lineHoldsOnlyBlanks
                    )
                }
                if !ctx.collected.isEmpty { break }
            }

            readOffset = min(i, bufLen)
        }

        private func nextRowsPiece(generation: Int) throws -> Data? {
            do {
                return try autoreleasepool {
                    guard let piece = try nextRowsRange(generation: generation) else { return nil }
                    return Data(nsBuffer.substring(with: piece).utf8)
                }
            } catch {
                rowsFailure = error
                copyRows = nil
                finished = true
                closeFile()
                SQLFileParser.logger.error("SQL file parsing failed: \(error.localizedDescription)")
                throw error
            }
        }

        private func passUnreadRows() throws {
            while copyRows != nil, !finished, !Task.isCancelled {
                _ = try nextRowsRange(generation: copyGeneration)
            }
        }

        // The next piece's range in the buffer, valid until the next chunk is read.
        private func nextRowsRange(generation: Int) throws -> NSRange? {
            while !finished, generation == copyGeneration,
                  let step = copyRows?.scan(nsBuffer, from: readOffset, atEndOfInput: ctx.atEndOfInput) {
                guard case let .advance(length, skipped, lineFeeds, endsRows) = step else {
                    try readChunk()
                    continue
                }
                let piece = NSRange(location: readOffset, length: length)
                readOffset += length + skipped
                ctx.currentLine += lineFeeds
                if endsRows {
                    copyRows = nil
                    ctx.resumeAfterCopyRows()
                }
                if length > 0 { return piece }
            }
            return nil
        }

        private func emitTrailingStatement() {
            ctx.pendingSlashLine = false
            ctx.pendingSlashTrailing.removeAll()
            if ctx.readsBatches {
                SQLFileParser.yieldBatch(&ctx, repeatCount: 1, nextBatchStart: ctx.unitsBeforeBuffer + readOffset)
                return
            }
            SQLFileParser.flushWord(&ctx)
            SQLFileParser.settleHeldEnd(&ctx, word: nil)
            guard ctx.hasStatementContent else { return }
            let text = SQLFileParser.trimmedStatement(ctx)
            if SQLFileParser.delimiterDirective(ctx) == nil {
                ctx.collected.append(
                    ParsedStatement(statement: text, lineNumber: ctx.statementStartLine, repeatCount: 1)
                )
            }
        }

        private func openFileIfNeeded() throws -> FileHandle {
            if let fileHandle {
                return fileHandle
            }
            let handle = try FileHandle(forReadingFrom: url)
            fileHandle = handle
            // Taken from the open handle; a size of 0 leaves the import's bar on statements.
            if onRead != nil {
                var info = stat()
                fileSize = fstat(handle.fileDescriptor, &info) == 0 ? Int64(info.st_size) : 0
            }
            return handle
        }

        private func closeFile() {
            guard let handle = fileHandle else { return }
            fileHandle = nil
            do {
                try handle.close()
            } catch {
                SQLFileParser.logger.warning(
                    "Failed to close file handle for \(self.url.path): \(error.localizedDescription)")
            }
        }
    }
}
