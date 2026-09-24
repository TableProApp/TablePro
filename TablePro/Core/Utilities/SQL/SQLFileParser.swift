//
//  SQLFileParser.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

final class SQLFileParser: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLFileParser")

    /// SQL Server takes at most 65,536 packets of 4,096 bytes in one request, about 134 million UTF-16 units of batch
    /// text: measured on Azure SQL Edge 15, a 133,900,000-unit batch ran and a 133,960,000-unit one closed the
    /// connection. A batch that reaches half of that ends at its next `;`, which leaves the statement it ends inside
    /// as much room again. A script whose `GO` lines stand that far apart is then sent in pieces the server takes,
    /// and held one piece at a time rather than whole.
    static let defaultBatchCutLength = 67_108_864

    private let batchCutLength: Int

    init(batchCutLength: Int = SQLFileParser.defaultBatchCutLength) {
        self.batchCutLength = batchCutLength
    }

    /// One statement the file holds, or on a grammar that cuts scripts into batches, one batch, with how many times
    /// the script runs it.
    private struct ParsedStatement {
        let statement: String
        let lineNumber: Int
        let repeatCount: Int
    }

    private enum ParserState {
        case normal
        case inSingleLineComment
        case inMultiLineComment
        case inSingleQuotedString
        case inDoubleQuotedString
        case inBacktickQuotedString
        case inTripleQuotedString
        case inBracketedIdentifier
        case inDollarQuote
        case inAlternativeQuote
    }

    private static let kSemicolon: unichar = 0x3B
    private static let kSingleQuote: unichar = 0x27
    private static let kDoubleQuote: unichar = 0x22
    private static let kBacktick: unichar = 0x60
    private static let kBackslash: unichar = 0x5C
    private static let kDash: unichar = 0x2D
    private static let kSlash: unichar = 0x2F
    private static let kStar: unichar = 0x2A
    private static let kHash: unichar = 0x23
    private static let kExclamation: unichar = 0x21
    private static let kNewline: unichar = 0x0A
    private static let kSpace: unichar = 0x20
    private static let kTab: unichar = 0x09
    private static let kCarriageReturn: unichar = 0x0D
    private static let kDollar: unichar = 0x24
    private static let kCapitalE: unichar = 0x45
    private static let kSmallE: unichar = 0x65
    private static let kCapitalM: unichar = 0x4D
    private static let kSmallM: unichar = 0x6D
    private static let kOpenBracket: unichar = 0x5B
    private static let kCloseBracket: unichar = 0x5D
    private static let kCapitalG: unichar = 0x47
    private static let kSmallG: unichar = 0x67

    nonisolated private static func needsLookahead(
        _ char: unichar,
        state: ParserState,
        grammar: SQLLexicalGrammar,
        delimiter: NSString,
        isSingleCharDelimiter: Bool
    ) -> Bool {
        switch state {
        case .normal:
            var result = char == kDash || char == kSlash || char == kBackslash || char == kStar
                || char == kSingleQuote || char == kDoubleQuote || char == kBacktick
            if char == kDollar
                && (grammar.dollarQuoteStyle != nil || grammar.contains(.dollarAndHashInIdentifiers)) {
                result = true
            }
            if grammar.contains(.escapeStringPrefix) && (char == kCapitalE || char == kSmallE) {
                result = true
            }
            if !isSingleCharDelimiter && char == delimiter.character(at: 0) {
                result = true
            }
            return result
        case .inSingleQuotedString, .inDoubleQuotedString, .inTripleQuotedString:
            return char == kSingleQuote || char == kDoubleQuote || char == kBackslash
        case .inBacktickQuotedString:
            return char == kBacktick || char == kBackslash
        case .inBracketedIdentifier:
            return char == kCloseBracket
        case .inMultiLineComment:
            return char == kStar || char == kSlash
        case .inSingleLineComment:
            return false
        case .inDollarQuote:
            return char == kDollar
        case .inAlternativeQuote:
            return false
        }
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

    private static let delimiterPrefix = "DELIMITER "
    private static let delimiterPrefixLength = 10

    private static func extractDelimiterChange(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix(delimiterPrefix) else { return nil }
        let newDelim = String(trimmed.dropFirst(delimiterPrefixLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return newDelim.isEmpty ? nil : newDelim
    }

    private struct ParserContext {
        let grammar: SQLLexicalGrammar
        var state: ParserState = .normal
        let currentStatement: NSMutableString?
        var hasStatementContent = false
        var currentLine = 1
        var statementStartLine = 1
        var isConditionalComment = false
        var commentDepth = 0
        var currentDelimiter: NSString = ";" as NSString
        var isSingleCharDelimiter = true
        var dollarTag: String = ""
        var quoteChar: unichar = 0
        var backslashEscapesActive = false
        var collected: [ParsedStatement] = []

        /// SQL Server's tools read a script the way sqlcmd does: a line holding only `GO` ends a batch, the batch goes
        /// to the server whole with its `;` and its comments, and the `GO` line goes nowhere. The comments stay so the
        /// server's line numbers count the file's lines and a routine keeps the comments written inside it.
        ///
        /// Only a file that holds a `GO` line is read so. One that holds none was written to run a statement at a
        /// time, cut at each `;`: that is how every SQL Server dump TablePro wrote before it wrote `GO` lines reads,
        /// and read as one batch it fails on its first view with Msg 111, having run none of it.
        let readsBatches: Bool
        let batchCutLength: Int

        /// A SQL Server statement goes to the server as a batch of its own, so it keeps the comments written inside it
        /// for the same reasons a batch keeps all of its own. The ones before its first code stay out of it.
        let keepsStatementComments: Bool

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

        /// The statement grammar, for a dialect whose statement can own its `;`: a PL/SQL unit arrives whole with
        /// its own `;`, and so do a T-SQL `MERGE` and a `BEGIN...END` routine body. A batch keeps every `;` it holds,
        /// so a file read in batches needs none. Every other dialect has always split an import at each `;` and
        /// relies on `DELIMITER` or dollar quoting for a routine body, and keeps doing so.
        var boundaries: (any SQLStatementBoundaryTracking)?
        var word: [unichar] = []
        var alternativeQuoteCloser: unichar = 0
        var lineHasCode = false
        var pendingSlashLine = false
        var pendingSlashTrailing: [unichar] = []

        /// The unit before the one being read, carried across chunks, so a prefix like `E'` or `q'` is only a
        /// literal where a word could start.
        var previousUnit: unichar = 0x20

        /// Whether that unit belongs to a word or a name, which a letter glued to it continues. A number is neither,
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
            self.keepsStatementComments = grammar.contains(.batchSeparatorLines)
            self.boundaries = !readsBatches && SQLStatementBoundaries.statementsCanOwnTerminator(in: grammar)
                ? SQLStatementBoundaries.makeTracker(for: grammar)
                : nil
        }

        /// Whether the comment being read goes into the text sent.
        var keepsComments: Bool {
            readsBatches || (keepsStatementComments && hasStatementContent)
        }

        /// Whether the block comment being read goes into the statement, which a conditional comment always does,
        /// being SQL the server runs.
        var keepsCommentText: Bool {
            keepsComments || isConditionalComment
        }
    }

    private static func trimmedStatement(_ ctx: ParserContext) -> String {
        (ctx.currentStatement as NSString?)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func resetStatement(_ ctx: inout ParserContext) {
        ctx.currentStatement?.setString("")
        ctx.hasStatementContent = false
        ctx.boundaries?.reset()
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
        ctx.boundaries?.observeWord(word)
    }

    /// Tracks the word `char` belongs to and returns whether `char` starts an Oracle `q'...'` literal, which it does
    /// only at the start of a word.
    private static func observeWordCharacter(
        _ ctx: inout ParserContext,
        char: unichar,
        i: Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> WordStep {
        let readsAlternativeQuotes = ctx.grammar.contains(.alternativeQuoting)
        guard ctx.boundaries != nil || readsAlternativeQuotes else { return .none }
        let followsWord = ctx.previousUnitInWord
        ctx.previousUnitInWord = (followsWord && SqlBlockStructure.continuesWord(char, grammar: ctx.grammar))
            || (char >= 0x80 && SQLNonCodeSpan.isWordUnit(char))
        if !ctx.word.isEmpty {
            if SqlBlockStructure.continuesWord(char, grammar: ctx.grammar) {
                ctx.word.append(char)
                return .continues
            }
            flushWord(&ctx)
        }
        guard SqlBlockStructure.startsWord(nsBuffer, at: i, length: bufLen, grammar: ctx.grammar) else { return .none }
        if readsAlternativeQuotes, !SQLNonCodeSpan.isWordUnit(ctx.previousUnit),
           let quoteLength = alternativeQuotePrefixLength(nsBuffer, at: i, bufLen: bufLen) {
            if quoteLength > 0 {
                return .opensAlternativeQuote(prefixLength: quoteLength)
            }
            guard ctx.atEndOfInput else {
                ctx.previousUnitInWord = followsWord
                return .needsMoreData
            }
        }
        guard !followsWord else { return .none }
        ctx.previousUnitInWord = true
        if ctx.boundaries?.needsWords == true {
            ctx.word.append(char)
        }
        return .continues
    }

    private enum WordStep {
        case none
        case continues
        case needsMoreData
        case opensAlternativeQuote(prefixLength: Int)
    }

    /// The length of `q'<delim>` or `nq'<delim>` at `i`, zero when the buffer ends before the delimiter, or nil
    /// when `i` does not start one.
    private static func alternativeQuotePrefixLength(_ buffer: NSString, at i: Int, bufLen: Int) -> Int? {
        var cursor = i
        let first = buffer.character(at: cursor)
        if first == SqlLexer.smallN || first == SqlLexer.capitalN {
            cursor += 1
        }
        guard cursor < bufLen else { return 0 }
        let prefix = buffer.character(at: cursor)
        guard prefix == SqlLexer.smallQ || prefix == SqlLexer.capitalQ else { return nil }
        guard cursor + 1 < bufLen else { return 0 }
        guard buffer.character(at: cursor + 1) == kSingleQuote else { return nil }
        guard cursor + 2 < bufLen else { return 0 }
        guard !isWhitespace(buffer.character(at: cursor + 2)) else { return nil }
        return cursor + 3 - i
    }

    private static func alternativeQuoteCloser(for opener: unichar) -> unichar {
        switch opener {
        case 0x5B: return 0x5D
        case 0x28: return 0x29
        case 0x7B: return 0x7D
        case 0x3C: return 0x3E
        default: return opener
        }
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

    private static func processDelimiterChange(_ ctx: inout ParserContext, char: unichar) {
        guard ctx.grammar.contains(.delimiterDirective) else { return }
        guard char == kNewline && ctx.hasStatementContent else { return }
        let text = trimmedStatement(ctx)
        if let newDelim = extractDelimiterChange(text) {
            ctx.currentDelimiter = newDelim as NSString
            ctx.isSingleCharDelimiter = ctx.currentDelimiter.length == 1
                && ctx.currentDelimiter.character(at: 0) == kSemicolon
            resetStatement(&ctx)
        }
    }

    private struct StepResult {
        var advanced: Bool
        var deferred: Bool
    }

    private static func processNormalChar(
        _ ctx: inout ParserContext,
        char: unichar,
        nextChar: unichar?,
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

        switch observeWordCharacter(&ctx, char: char, i: i, nsBuffer: nsBuffer, bufLen: bufLen) {
        case .continues:
            (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
                ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
            appendChar(char, to: ctx.currentStatement)
            return StepResult(advanced: false, deferred: false)
        case .needsMoreData:
            return StepResult(advanced: false, deferred: true)
        case let .opensAlternativeQuote(prefixLength):
            (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
                ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
            appendRange(&ctx, from: i, to: i + prefixLength, in: nsBuffer)
            ctx.alternativeQuoteCloser = alternativeQuoteCloser(for: nsBuffer.character(at: i + prefixLength - 1))
            ctx.state = .inAlternativeQuote
            ctx.boundaries?.observeOpaqueToken()
            i += prefixLength
            return StepResult(advanced: true, deferred: false)
        case .none:
            break
        }

        processDelimiterChange(&ctx, char: char)

        if char == kDash && nextChar == kDash {
            if ctx.grammar.contains(.dashCommentsNeedWhitespace), i + 2 >= bufLen, !ctx.atEndOfInput {
                return StepResult(advanced: false, deferred: true)
            }
            if SqlLexer.startsDashComment(
                nsBuffer,
                at: i,
                length: bufLen,
                needsWhitespace: ctx.grammar.contains(.dashCommentsNeedWhitespace)
            ) {
                ctx.state = .inSingleLineComment
                ctx.boundaries?.observeGap()
                if ctx.keepsComments {
                    appendRange(&ctx, from: i, to: i + 2, in: nsBuffer)
                }
                i += 2
                return StepResult(advanced: true, deferred: false)
            }
        }

        if (char == kHash && ctx.grammar.contains(.hashLineComments))
            || (char == kSlash && nextChar == kSlash && ctx.grammar.contains(.doubleSlashLineComments)) {
            ctx.state = .inSingleLineComment
            ctx.boundaries?.observeGap()
            if ctx.keepsComments {
                appendChar(char, to: ctx.currentStatement)
            }
            return StepResult(advanced: false, deferred: false)
        }

        if char == kSlash, let next = nextChar, next == kStar {
            ctx.isConditionalComment = ctx.grammar.contains(.executableComments)
                && SqlLexer.executableCommentOpenerLength(nsBuffer, at: i, length: bufLen) != nil
            ctx.commentDepth = 1
            ctx.state = .inMultiLineComment
            if ctx.isConditionalComment {
                (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
                    ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
            } else {
                ctx.boundaries?.observeGap()
            }
            if ctx.keepsCommentText {
                appendChar(char, to: ctx.currentStatement)
                appendChar(next, to: ctx.currentStatement)
            }
            i += 2
            return StepResult(advanced: true, deferred: false)
        }

        if ctx.grammar.contains(.escapeStringPrefix)
            && (char == kCapitalE || char == kSmallE)
            && nextChar == kSingleQuote
            && !SQLNonCodeSpan.isWordUnit(ctx.previousUnit) {
            (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
                ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
            appendChar(char, to: ctx.currentStatement)
            appendChar(kSingleQuote, to: ctx.currentStatement)
            ctx.state = .inSingleQuotedString
            ctx.quoteChar = kSingleQuote
            ctx.backslashEscapesActive = true
            i += 2
            return StepResult(advanced: true, deferred: false)
        }

        if char == kOpenBracket, ctx.grammar.contains(.bracketQuotedIdentifiers) {
            (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
                ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
            appendChar(char, to: ctx.currentStatement)
            ctx.state = .inBracketedIdentifier
            ctx.boundaries?.observeOpaqueToken()
            return StepResult(advanced: false, deferred: false)
        }

        if let style = ctx.grammar.dollarQuoteStyle, char == kDollar {
            switch SqlDollarQuote.scanOpener(at: i, in: nsBuffer, bufLen: bufLen, style: style) {
            case .opener(let length, let tag):
                (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
                    ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
                if let target = ctx.currentStatement {
                    let openerRange = NSRange(location: i, length: length)
                    target.append(nsBuffer.substring(with: openerRange))
                }
                ctx.state = .inDollarQuote
                ctx.dollarTag = tag
                i += length
                return StepResult(advanced: true, deferred: false)
            case .needsMoreData where !ctx.atEndOfInput:
                return StepResult(advanced: false, deferred: true)
            case .needsMoreData, .notOpener:
                break
            }
        }

        if isQuote(char, grammar: ctx.grammar) {
            if ctx.grammar.contains(.tripleQuotedStrings), char != kBacktick, i + 2 >= bufLen, !ctx.atEndOfInput {
                return StepResult(advanced: false, deferred: true)
            }
            if ctx.grammar.contains(.tripleQuotedStrings), SqlLexer.startsTripleQuote(nsBuffer, at: i, length: bufLen) {
                openTripleQuote(&ctx, quote: char, at: i, in: nsBuffer)
                i += 3
                return StepResult(advanced: true, deferred: false)
            }
        }

        if let advanced = processQuoteOpen(&ctx, char: char, nextChar: nextChar) {
            ctx.boundaries?.observeOpaqueToken()
            if advanced { i += 2 }
            return StepResult(advanced: advanced, deferred: false)
        }

        if ctx.isSingleCharDelimiter && char == kSemicolon {
            processSemicolon(&ctx, at: i)
            return StepResult(advanced: false, deferred: false)
        }

        if ctx.grammar.contains(.slashLineTerminators) && char == kSlash && !ctx.lineHasCode {
            ctx.pendingSlashLine = true
            return StepResult(advanced: false, deferred: false)
        }

        if !ctx.isSingleCharDelimiter
            && matchesDelimiter(at: i, delimiter: ctx.currentDelimiter, in: nsBuffer, bufLen: bufLen) {
            yieldAndReset(&ctx)
            i += ctx.currentDelimiter.length
            return StepResult(advanced: true, deferred: false)
        }

        if !ctx.hasStatementContent && !isWhitespace(char) {
            ctx.statementStartLine = ctx.currentLine
            ctx.hasStatementContent = true
        }
        if isWhitespace(char) {
            ctx.boundaries?.observeGap()
        } else {
            ctx.boundaries?.observeSymbol(char)
        }
        appendChar(char, to: ctx.currentStatement)
        return StepResult(advanced: false, deferred: false)
    }

    /// A `;` ends the statement unless the grammar holds it inside a PL/SQL unit or a routine body, and a statement
    /// that owns the `;` that ends it keeps it. In a batch it ends nothing, unless the batch has grown past what the
    /// server takes in one request.
    private static func processSemicolon(_ ctx: inout ParserContext, at i: Int) {
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
        let endsStatement = ctx.boundaries?.observeSemicolon() ?? true
        guard endsStatement else {
            appendChar(kSemicolon, to: ctx.currentStatement)
            return
        }
        if ctx.boundaries?.terminator == .partOfStatement, ctx.hasStatementContent {
            appendChar(kSemicolon, to: ctx.currentStatement)
        }
        yieldAndReset(&ctx)
    }

    private static func processAlternativeQuote(
        _ ctx: inout ParserContext,
        i: inout Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult {
        let start = i
        var pos = i
        while pos < bufLen {
            let ch = nsBuffer.character(at: pos)
            if pos > start && ch == kNewline {
                ctx.currentLine += 1
            }
            if ch == ctx.alternativeQuoteCloser {
                if pos + 1 >= bufLen {
                    if ctx.atEndOfInput {
                        pos += 1
                        continue
                    }
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                if nsBuffer.character(at: pos + 1) == kSingleQuote {
                    pos += 2
                    ctx.state = .normal
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: false)
                }
            }
            pos += 1
        }
        appendRange(&ctx, from: start, to: pos, in: nsBuffer)
        i = pos
        return StepResult(advanced: true, deferred: false)
    }

    private static func isQuote(_ char: unichar, grammar: SQLLexicalGrammar) -> Bool {
        grammar.isQuote(char)
    }

    private static func processQuoteOpen(
        _ ctx: inout ParserContext,
        char: unichar,
        nextChar: unichar?
    ) -> Bool? {
        guard isQuote(char, grammar: ctx.grammar) else { return nil }
        if let next = nextChar, next == char {
            (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
                ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
            appendChar(char, to: ctx.currentStatement)
            appendChar(next, to: ctx.currentStatement)
            return true
        }
        switch char {
        case kSingleQuote: ctx.state = .inSingleQuotedString
        case kDoubleQuote: ctx.state = .inDoubleQuotedString
        default: ctx.state = .inBacktickQuotedString
        }
        ctx.quoteChar = char
        ctx.backslashEscapesActive = ctx.grammar.backslashEscapes(inQuote: char)
        (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
            ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
        appendChar(char, to: ctx.currentStatement)
        return false
    }

    private static func openTripleQuote(_ ctx: inout ParserContext, quote: unichar, at i: Int, in buffer: NSString) {
        (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
            ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
        appendRange(&ctx, from: i, to: i + 3, in: buffer)
        ctx.state = .inTripleQuotedString
        ctx.quoteChar = quote
        ctx.backslashEscapesActive = ctx.grammar.backslashEscapes(inQuote: quote)
        ctx.boundaries?.observeOpaqueToken()
    }

    /// Runs a triple-quoted literal to the three quotes that close it, holding back a quote or a backslash the buffer
    /// ends on until the next chunk shows what follows.
    private static func processTripleQuotedString(
        _ ctx: inout ParserContext,
        i: inout Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult {
        let start = i
        var pos = i
        while pos < bufLen {
            let ch = nsBuffer.character(at: pos)
            if pos > start && ch == kNewline {
                ctx.currentLine += 1
            }
            if ctx.backslashEscapesActive && ch == kBackslash {
                guard pos + 1 < bufLen || ctx.atEndOfInput else {
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                pos += 2
                continue
            }
            if ch == ctx.quoteChar {
                guard pos + 2 < bufLen || ctx.atEndOfInput else {
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                if SqlLexer.startsTripleQuote(nsBuffer, at: pos, length: bufLen) {
                    pos += 3
                    ctx.state = .normal
                    ctx.backslashEscapesActive = false
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: false)
                }
            }
            pos += 1
        }
        appendRange(&ctx, from: start, to: min(pos, bufLen), in: nsBuffer)
        i = min(pos, bufLen)
        return StepResult(advanced: true, deferred: false)
    }

    /// Runs a `[...]` identifier to its `]`, which `]]` does not close where the grammar escapes it.
    private static func processBracketedIdentifier(
        _ ctx: inout ParserContext,
        i: inout Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult {
        let start = i
        var pos = i
        let doubledEscapes = ctx.grammar.contains(.doubledClosingBracketEscapes)
        while pos < bufLen {
            let ch = nsBuffer.character(at: pos)
            if pos > start && ch == kNewline {
                ctx.currentLine += 1
            }
            guard ch == kCloseBracket else {
                pos += 1
                continue
            }
            if doubledEscapes {
                guard pos + 1 < bufLen || ctx.atEndOfInput else {
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                if pos + 1 < bufLen, nsBuffer.character(at: pos + 1) == kCloseBracket {
                    pos += 2
                    continue
                }
            }
            pos += 1
            ctx.state = .normal
            appendRange(&ctx, from: start, to: pos, in: nsBuffer)
            i = pos
            return StepResult(advanced: true, deferred: false)
        }
        appendRange(&ctx, from: start, to: pos, in: nsBuffer)
        i = pos
        return StepResult(advanced: true, deferred: false)
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

    private static func processMultiLineComment(
        _ ctx: inout ParserContext,
        char: unichar,
        nextChar: unichar?,
        i: inout Int
    ) -> Bool {
        if ctx.keepsCommentText {
            appendChar(char, to: ctx.currentStatement)
        }
        if char == kSlash, nextChar == kStar, !ctx.isConditionalComment, ctx.grammar.contains(.nestedBlockComments) {
            if ctx.keepsComments {
                appendChar(kStar, to: ctx.currentStatement)
            }
            ctx.commentDepth += 1
            i += 2
            return true
        }
        if char == kStar, let next = nextChar, next == kSlash {
            if ctx.keepsCommentText {
                appendChar(next, to: ctx.currentStatement)
            }
            ctx.commentDepth -= 1
            i += 2
            guard ctx.commentDepth <= 0 || ctx.isConditionalComment else { return true }
            ctx.state = .normal
            ctx.isConditionalComment = false
            ctx.commentDepth = 0
            return true
        }
        return false
    }

    private static func appendRange(
        _ ctx: inout ParserContext,
        from start: Int,
        to end: Int,
        in buffer: NSString
    ) {
        guard let target = ctx.currentStatement, end > start else { return }
        target.append(buffer.substring(with: NSRange(location: start, length: end - start)))
    }

    private static func processQuotedString(
        _ ctx: inout ParserContext,
        quoteChar: unichar,
        i: inout Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult {
        let start = i
        var pos = i
        let escapesActive = ctx.backslashEscapesActive

        while pos < bufLen {
            let ch = nsBuffer.character(at: pos)
            if pos > start && ch == kNewline {
                ctx.currentLine += 1
            }

            if escapesActive && ch == kBackslash {
                if pos + 1 >= bufLen {
                    if ctx.atEndOfInput {
                        pos += 1
                        continue
                    }
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                let next = nsBuffer.character(at: pos + 1)
                if next == kNewline { ctx.currentLine += 1 }
                pos += 2
                continue
            }

            if ch == quoteChar {
                if pos + 1 >= bufLen && !ctx.atEndOfInput {
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                let next: unichar? = pos + 1 < bufLen ? nsBuffer.character(at: pos + 1) : nil
                if next == quoteChar {
                    pos += 2
                    continue
                }
                pos += 1
                ctx.state = .normal
                ctx.backslashEscapesActive = false
                appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                i = pos
                return StepResult(advanced: true, deferred: false)
            }

            pos += 1
        }

        appendRange(&ctx, from: start, to: pos, in: nsBuffer)
        i = pos
        return StepResult(advanced: true, deferred: false)
    }

    private static func processDollarQuote(
        _ ctx: inout ParserContext,
        i: inout Int,
        nsBuffer: NSString,
        bufLen: Int
    ) -> StepResult {
        let start = i
        var pos = i
        let closeLen = (ctx.dollarTag as NSString).length + 2

        while pos < bufLen {
            let ch = nsBuffer.character(at: pos)
            if pos > start && ch == kNewline {
                ctx.currentLine += 1
            }

            if ch == kDollar {
                if pos + closeLen > bufLen {
                    if ctx.atEndOfInput {
                        pos += 1
                        continue
                    }
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                if SqlDollarQuote.matchesClose(at: pos, tag: ctx.dollarTag, in: nsBuffer, bufLen: bufLen) {
                    pos += closeLen
                    ctx.state = .normal
                    ctx.dollarTag = ""
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: false)
                }
            }
            pos += 1
        }

        appendRange(&ctx, from: start, to: pos, in: nsBuffer)
        i = pos
        return StepResult(advanced: true, deferred: false)
    }

    /// The file's statements in order, each as many times as the script runs it: a batch ended by `GO 5` comes five
    /// times, one run each, handed out one at a time rather than copied.
    func parseFile(
        url: URL,
        encoding: String.Encoding,
        grammar: SQLLexicalGrammar
    ) -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        let session = ParseSession(
            url: url, encoding: encoding, grammar: grammar, countOnly: false, batchCutLength: batchCutLength
        )
        return AsyncThrowingStream(unfolding: {
            try await session.nextRun()
        })
    }

    /// How many statements the import runs, a batch ended by `GO 5` counting five times. The runs are added up rather
    /// than walked, because a count can reach `Int32.max`.
    func countStatements(
        url: URL,
        encoding: String.Encoding,
        grammar: SQLLexicalGrammar
    ) async throws -> Int {
        let session = ParseSession(
            url: url, encoding: encoding, grammar: grammar, countOnly: true, batchCutLength: batchCutLength
        )
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
        private let grammar: SQLLexicalGrammar
        private let batchCutLength: Int
        private let chunkSize = 65_536

        private var fileHandle: FileHandle?
        private var ctx: ParserContext
        private let nsBuffer = NSMutableString()
        private var decoder: SQLChunkDecoder
        private var emitIndex = 0
        private var finished = false
        private var readingSettled: Bool
        private var repeating: ParsedStatement?
        private var remainingRuns = 0

        init(
            url: URL,
            encoding: String.Encoding,
            grammar: SQLLexicalGrammar,
            countOnly: Bool,
            batchCutLength: Int,
            reading: Reading = .fromFile
        ) {
            self.url = url
            self.encoding = encoding
            self.grammar = grammar
            self.batchCutLength = batchCutLength
            self.decoder = SQLChunkDecoder(encoding: encoding)
            self.readingSettled = reading == .batches
            self.ctx = ParserContext(
                grammar: grammar,
                currentStatement: countOnly ? nil : NSMutableString(),
                batchCutLength: batchCutLength,
                readsBatches: reading == .batches
            )
        }

        deinit {
            closeFile()
        }

        func nextRun() async throws -> (statement: String, lineNumber: Int)? {
            if let repeating, remainingRuns > 0 {
                remainingRuns -= 1
                return (repeating.statement, repeating.lineNumber)
            }
            guard let next = try await nextStatement() else { return nil }
            repeating = next
            remainingRuns = next.repeatCount - 1
            return (next.statement, next.lineNumber)
        }

        func nextStatement() async throws -> ParsedStatement? {
            while true {
                if emitIndex < ctx.collected.count {
                    let item = ctx.collected[emitIndex]
                    emitIndex += 1
                    return item
                }
                ctx.collected.removeAll(keepingCapacity: true)
                emitIndex = 0

                if finished {
                    return nil
                }

                do {
                    try settleReading()
                    guard !Task.isCancelled else {
                        finished = true
                        closeFile()
                        return nil
                    }
                    try advanceOneChunk()
                } catch {
                    finished = true
                    closeFile()
                    SQLFileParser.logger.error("SQL file parsing failed: \(error.localizedDescription)")
                    throw error
                }
            }
        }

        /// Reads the file for a `GO` line before any of it is handed out, because a batch cannot be put back together
        /// from statements already sent.
        private func settleReading() throws {
            guard !readingSettled else { return }
            readingSettled = true
            guard grammar.contains(.batchSeparatorLines) else { return }
            let scan = ParseSession(
                url: url,
                encoding: encoding,
                grammar: grammar,
                countOnly: true,
                batchCutLength: batchCutLength,
                reading: .batches
            )
            guard try scan.findsBatchSeparator() else { return }
            ctx = ParserContext(
                grammar: grammar,
                currentStatement: ctx.currentStatement,
                batchCutLength: batchCutLength,
                readsBatches: true
            )
        }

        /// Whether the file holds a `GO` line, read the way a script is cut into batches, so one inside a literal or a
        /// comment does not count. Reading stops at the first.
        func findsBatchSeparator() throws -> Bool {
            defer { closeFile() }
            while !finished, !ctx.sawBatchSeparator, !Task.isCancelled {
                try advanceOneChunk()
                ctx.collected.removeAll(keepingCapacity: true)
            }
            return ctx.sawBatchSeparator
        }

        private func advanceOneChunk() throws {
            let handle = try openFileIfNeeded()
            let rawData = handle.readData(ofLength: chunkSize)

            if rawData.isEmpty && !decoder.hasPendingBytes {
                ctx.atEndOfInput = true
                processBuffer()
                emitTrailingStatement()
                finished = true
                closeFile()
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

            nsBuffer.append(chunk)
            processBuffer()
        }

        private func processBuffer() {
            let bufLen = nsBuffer.length
            var i = 0

            while i < bufLen {
                let stepStart = i
                let char = nsBuffer.character(at: i)
                let nextChar: unichar? = (i + 1 < bufLen) ? nsBuffer.character(at: i + 1) : nil

                if nextChar == nil && !ctx.atEndOfInput && SQLFileParser.needsLookahead(
                    char,
                    state: ctx.state,
                    grammar: grammar,
                    delimiter: ctx.currentDelimiter,
                    isSingleCharDelimiter: ctx.isSingleCharDelimiter
                ) {
                    break
                }

                if char == SQLFileParser.kNewline { ctx.currentLine += 1 }
                var didManuallyAdvance = false
                var shouldDefer = false

                switch ctx.state {
                case .normal:
                    let result = SQLFileParser.processNormalChar(
                        &ctx, char: char, nextChar: nextChar,
                        i: &i, nsBuffer: nsBuffer, bufLen: bufLen)
                    didManuallyAdvance = result.advanced
                    shouldDefer = result.deferred

                case .inSingleLineComment:
                    if ctx.keepsComments {
                        SQLFileParser.appendChar(char, to: ctx.currentStatement)
                    }
                    if char == SQLFileParser.kNewline
                        || (char == SQLFileParser.kCarriageReturn
                            && grammar.contains(.carriageReturnEndsLineComments)) {
                        ctx.state = .normal
                    }

                case .inMultiLineComment:
                    didManuallyAdvance = SQLFileParser.processMultiLineComment(
                        &ctx, char: char, nextChar: nextChar, i: &i)

                case .inSingleQuotedString:
                    let result = SQLFileParser.processQuotedString(
                        &ctx, quoteChar: SQLFileParser.kSingleQuote,
                        i: &i, nsBuffer: nsBuffer, bufLen: bufLen)
                    didManuallyAdvance = result.advanced
                    shouldDefer = result.deferred

                case .inDoubleQuotedString:
                    let result = SQLFileParser.processQuotedString(
                        &ctx, quoteChar: SQLFileParser.kDoubleQuote,
                        i: &i, nsBuffer: nsBuffer, bufLen: bufLen)
                    didManuallyAdvance = result.advanced
                    shouldDefer = result.deferred

                case .inBacktickQuotedString:
                    let result = SQLFileParser.processQuotedString(
                        &ctx, quoteChar: SQLFileParser.kBacktick,
                        i: &i, nsBuffer: nsBuffer, bufLen: bufLen)
                    didManuallyAdvance = result.advanced
                    shouldDefer = result.deferred

                case .inTripleQuotedString:
                    let result = SQLFileParser.processTripleQuotedString(
                        &ctx, i: &i, nsBuffer: nsBuffer, bufLen: bufLen)
                    didManuallyAdvance = result.advanced
                    shouldDefer = result.deferred

                case .inBracketedIdentifier:
                    let result = SQLFileParser.processBracketedIdentifier(
                        &ctx, i: &i, nsBuffer: nsBuffer, bufLen: bufLen)
                    didManuallyAdvance = result.advanced
                    shouldDefer = result.deferred

                case .inDollarQuote:
                    let result = SQLFileParser.processDollarQuote(
                        &ctx, i: &i,
                        nsBuffer: nsBuffer, bufLen: bufLen)
                    didManuallyAdvance = result.advanced
                    shouldDefer = result.deferred

                case .inAlternativeQuote:
                    let result = SQLFileParser.processAlternativeQuote(
                        &ctx, i: &i,
                        nsBuffer: nsBuffer, bufLen: bufLen)
                    didManuallyAdvance = result.advanced
                    shouldDefer = result.deferred
                }

                if shouldDefer { break }
                if char == SQLFileParser.kNewline {
                    ctx.lineHasCode = false
                } else if !SQLFileParser.isLineBlank(char) && !ctx.pendingSlashLine {
                    ctx.lineHasCode = true
                }
                if !didManuallyAdvance { i += 1 }
                if i > 0, i <= bufLen {
                    ctx.previousUnit = nsBuffer.character(at: i - 1)
                }
                if ctx.state != .normal {
                    ctx.previousUnitInWord = false
                }
                if ctx.readsBatches {
                    ctx.lineHoldsOnlyBlanks = SQLFileBatchLines.holdsOnlyBlanks(
                        nsBuffer, from: stepStart, to: min(i, bufLen), before: ctx.lineHoldsOnlyBlanks
                    )
                }
            }

            ctx.unitsBeforeBuffer += min(i, bufLen)
            if i < bufLen {
                nsBuffer.deleteCharacters(in: NSRange(location: 0, length: i))
            } else {
                nsBuffer.setString("")
            }
        }

        private func emitTrailingStatement() {
            ctx.pendingSlashLine = false
            ctx.pendingSlashTrailing.removeAll()
            if ctx.readsBatches {
                SQLFileParser.yieldBatch(&ctx, repeatCount: 1, nextBatchStart: ctx.unitsBeforeBuffer)
                return
            }
            guard ctx.hasStatementContent else { return }
            let text = SQLFileParser.trimmedStatement(ctx)
            if SQLFileParser.extractDelimiterChange(text) == nil {
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
