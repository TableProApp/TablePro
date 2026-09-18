//
//  SQLFileParser.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class SQLFileParser: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLFileParser")

    private enum ParserState {
        case normal
        case inSingleLineComment
        case inMultiLineComment
        case inSingleQuotedString
        case inDoubleQuotedString
        case inBacktickQuotedString
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

    nonisolated private static func needsLookahead(
        _ char: unichar,
        state: ParserState,
        dialect: SqlDialect,
        delimiter: NSString,
        isSingleCharDelimiter: Bool
    ) -> Bool {
        switch state {
        case .normal:
            var result = char == kDash || char == kSlash || char == kBackslash || char == kStar
                || char == kSingleQuote || char == kDoubleQuote || char == kBacktick
            if dialect == .oracle && char == kDollar {
                result = true
            }
            if dialect.supportsDollarQuotes && char == kDollar {
                result = true
            }
            if dialect.supportsEscapeStringPrefix && (char == kCapitalE || char == kSmallE) {
                result = true
            }
            if !isSingleCharDelimiter && char == delimiter.character(at: 0) {
                result = true
            }
            return result
        case .inSingleQuotedString:
            return char == kSingleQuote || char == kBackslash
        case .inDoubleQuotedString:
            return char == kDoubleQuote || char == kBackslash
        case .inBacktickQuotedString:
            return char == kBacktick
        case .inMultiLineComment:
            return char == kStar
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
        let dialect: SqlDialect
        var state: ParserState = .normal
        let currentStatement: NSMutableString?
        var hasStatementContent = false
        var currentLine = 1
        var statementStartLine = 1
        var isConditionalComment = false
        var currentDelimiter: NSString = ";" as NSString
        var isSingleCharDelimiter = true
        var dollarTag: String = ""
        var backslashEscapesActive = false
        var collected: [(statement: String, lineNumber: Int)] = []

        /// Oracle's statement grammar, so a PL/SQL unit arrives whole with its own `;`. Every other dialect has
        /// always split an import at each `;` and relies on `DELIMITER` or dollar quoting for a routine body, and
        /// keeps doing so.
        var boundaries: PLSQLUnitTracker?
        var word: [unichar] = []
        var alternativeQuoteCloser: unichar = 0
        var lineHasCode = false
        var pendingSlashLine = false
        var pendingSlashTrailing: [unichar] = []

        /// Set for the last pass over the buffer, once the file has nothing more to give. A character held back for
        /// the one after it is settled with nothing after it, instead of being left in the buffer and dropped.
        var atEndOfInput = false

        init(dialect: SqlDialect, currentStatement: NSMutableString?) {
            self.dialect = dialect
            self.currentStatement = currentStatement
            self.boundaries = dialect == .oracle ? PLSQLUnitTracker() : nil
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
        guard ctx.boundaries != nil else { return .none }
        if !ctx.word.isEmpty {
            if SqlBlockStructure.continuesWord(char, dialect: ctx.dialect) {
                ctx.word.append(char)
                return .continues
            }
            flushWord(&ctx)
        }
        guard SqlBlockStructure.startsWord(nsBuffer, at: i, length: bufLen, dialect: ctx.dialect) else { return .none }
        if let quoteLength = alternativeQuotePrefixLength(nsBuffer, at: i, bufLen: bufLen) {
            if quoteLength > 0 {
                return .opensAlternativeQuote(prefixLength: quoteLength)
            }
            guard ctx.atEndOfInput else { return .needsMoreData }
        }
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
        guard ctx.dialect == .mysql || ctx.dialect == .generic else { return }
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
            ctx.state = .inSingleLineComment
            i += 2
            return StepResult(advanced: true, deferred: false)
        }

        if char == kHash && (ctx.dialect == .mysql || ctx.dialect == .generic) {
            ctx.state = .inSingleLineComment
            return StepResult(advanced: false, deferred: false)
        }

        if char == kSlash, let next = nextChar, next == kStar {
            let thirdChar: unichar? = (i + 2 < bufLen) ? nsBuffer.character(at: i + 2) : nil
            ctx.isConditionalComment = (ctx.dialect == .mysql) && thirdChar == kExclamation
            ctx.state = .inMultiLineComment
            if ctx.isConditionalComment {
                (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
                    ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
                appendChar(char, to: ctx.currentStatement)
                appendChar(next, to: ctx.currentStatement)
            }
            i += 2
            return StepResult(advanced: true, deferred: false)
        }

        if ctx.dialect.supportsEscapeStringPrefix
            && (char == kCapitalE || char == kSmallE)
            && nextChar == kSingleQuote {
            (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
                ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
            appendChar(char, to: ctx.currentStatement)
            appendChar(kSingleQuote, to: ctx.currentStatement)
            ctx.state = .inSingleQuotedString
            ctx.backslashEscapesActive = true
            i += 2
            return StepResult(advanced: true, deferred: false)
        }

        if ctx.dialect.supportsDollarQuotes && char == kDollar {
            switch SqlDollarQuote.scanOpener(at: i, in: nsBuffer, bufLen: bufLen) {
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

        if let advanced = processQuoteOpen(&ctx, char: char, nextChar: nextChar) {
            ctx.boundaries?.observeOpaqueToken()
            if advanced { i += 2 }
            return StepResult(advanced: advanced, deferred: false)
        }

        if ctx.isSingleCharDelimiter && char == kSemicolon {
            processSemicolon(&ctx)
            return StepResult(advanced: false, deferred: false)
        }

        if ctx.dialect.endsStatementsAtSlashLines && char == kSlash && !ctx.lineHasCode {
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
        if !isWhitespace(char) {
            ctx.boundaries?.observeSymbol(char)
        }
        appendChar(char, to: ctx.currentStatement)
        return StepResult(advanced: false, deferred: false)
    }

    /// A `;` ends the statement unless Oracle's grammar holds it inside a PL/SQL unit, and a unit keeps the `;` that
    /// ends it.
    private static func processSemicolon(_ ctx: inout ParserContext) {
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

    private static func processQuoteOpen(
        _ ctx: inout ParserContext,
        char: unichar,
        nextChar: unichar?
    ) -> Bool? {
        let quoteMapping: [(unichar, ParserState)] = [
            (kSingleQuote, .inSingleQuotedString),
            (kDoubleQuote, .inDoubleQuotedString),
            (kBacktick, .inBacktickQuotedString)
        ]
        for (quoteChar, targetState) in quoteMapping {
            guard char == quoteChar else { continue }
            if let next = nextChar, next == quoteChar {
                (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
                    ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
                appendChar(char, to: ctx.currentStatement)
                appendChar(next, to: ctx.currentStatement)
                return true
            }
            ctx.state = targetState
            switch targetState {
            case .inSingleQuotedString:
                ctx.backslashEscapesActive = ctx.dialect.requiresBackslashEscapesInSingleQuotes
            case .inDoubleQuotedString:
                ctx.backslashEscapesActive = ctx.dialect == .mysql
            default:
                ctx.backslashEscapesActive = false
            }
            (ctx.hasStatementContent, ctx.statementStartLine) = markContent(
                ctx.hasStatementContent, ctx.statementStartLine, ctx.currentLine)
            appendChar(char, to: ctx.currentStatement)
            return false
        }
        return nil
    }

    private static func yieldAndReset(_ ctx: inout ParserContext) {
        if ctx.hasStatementContent {
            let text = trimmedStatement(ctx)
            ctx.collected.append((text, ctx.statementStartLine))
        }
        resetStatement(&ctx)
    }

    private static func processMultiLineComment(
        _ ctx: inout ParserContext,
        char: unichar,
        nextChar: unichar?,
        i: inout Int
    ) -> Bool {
        if ctx.isConditionalComment {
            appendChar(char, to: ctx.currentStatement)
        }
        if char == kStar, let next = nextChar, next == kSlash {
            if ctx.isConditionalComment {
                appendChar(next, to: ctx.currentStatement)
            }
            ctx.state = .normal
            ctx.isConditionalComment = false
            i += 2
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

    func parseFile(
        url: URL,
        encoding: String.Encoding,
        dialect: SqlDialect = .generic,
        countOnly: Bool = false
    ) -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        let session = ParseSession(url: url, encoding: encoding, dialect: dialect, countOnly: countOnly)
        return AsyncThrowingStream(unfolding: {
            try await session.next()
        })
    }

    private final class ParseSession: @unchecked Sendable {
        private let url: URL
        private let encoding: String.Encoding
        private let dialect: SqlDialect
        private let chunkSize = 65_536

        private var fileHandle: FileHandle?
        private var ctx: ParserContext
        private let nsBuffer = NSMutableString()
        private var decoder: SQLChunkDecoder
        private var emitIndex = 0
        private var finished = false

        init(url: URL, encoding: String.Encoding, dialect: SqlDialect, countOnly: Bool) {
            self.url = url
            self.encoding = encoding
            self.dialect = dialect
            self.decoder = SQLChunkDecoder(encoding: encoding)
            self.ctx = ParserContext(
                dialect: dialect,
                currentStatement: countOnly ? nil : NSMutableString()
            )
        }

        deinit {
            closeFile()
        }

        func next() async throws -> (statement: String, lineNumber: Int)? {
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
                if Task.isCancelled {
                    finished = true
                    closeFile()
                    return nil
                }

                do {
                    try advanceOneChunk()
                } catch {
                    finished = true
                    closeFile()
                    SQLFileParser.logger.error("SQL file parsing failed: \(error.localizedDescription)")
                    throw error
                }
            }
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
                let char = nsBuffer.character(at: i)
                let nextChar: unichar? = (i + 1 < bufLen) ? nsBuffer.character(at: i + 1) : nil

                if nextChar == nil && !ctx.atEndOfInput && SQLFileParser.needsLookahead(
                    char,
                    state: ctx.state,
                    dialect: dialect,
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
                    if char == SQLFileParser.kNewline {
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
            }

            if i < bufLen {
                nsBuffer.deleteCharacters(in: NSRange(location: 0, length: i))
            } else {
                nsBuffer.setString("")
            }
        }

        private func emitTrailingStatement() {
            ctx.pendingSlashLine = false
            ctx.pendingSlashTrailing.removeAll()
            guard ctx.hasStatementContent else { return }
            let text = SQLFileParser.trimmedStatement(ctx)
            if SQLFileParser.extractDelimiterChange(text) == nil {
                ctx.collected.append((text, ctx.statementStartLine))
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

    func countStatements(
        url: URL,
        encoding: String.Encoding,
        dialect: SqlDialect = .generic
    ) async throws -> Int {
        var count = 0

        for try await _ in parseFile(url: url, encoding: encoding, dialect: dialect, countOnly: true) {
            try Task.checkCancellation()
            count += 1
        }

        return count
    }
}
