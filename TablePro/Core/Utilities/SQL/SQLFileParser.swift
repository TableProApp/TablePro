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
    }

    private static func trimmedStatement(_ ctx: ParserContext) -> String {
        (ctx.currentStatement as NSString?)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func resetStatement(_ ctx: inout ParserContext) {
        ctx.currentStatement?.setString("")
        ctx.hasStatementContent = false
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
            case .needsMoreData:
                return StepResult(advanced: false, deferred: true)
            case .notOpener:
                break
            }
        }

        if let advanced = processQuoteOpen(&ctx, char: char, nextChar: nextChar) {
            if advanced { i += 2 }
            return StepResult(advanced: advanced, deferred: false)
        }

        if ctx.isSingleCharDelimiter && char == kSemicolon {
            yieldAndReset(&ctx)
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
        appendChar(char, to: ctx.currentStatement)
        return StepResult(advanced: false, deferred: false)
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
                if pos + 1 >= bufLen {
                    appendRange(&ctx, from: start, to: pos, in: nsBuffer)
                    i = pos
                    return StepResult(advanced: true, deferred: true)
                }
                let next = nsBuffer.character(at: pos + 1)
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

    private static func decodeChunkOrCarryTail(
        rawData: Data,
        pendingTail: inout Data,
        encoding: String.Encoding
    ) -> String? {
        var data = pendingTail
        data.append(rawData)
        pendingTail.removeAll(keepingCapacity: true)

        if let decoded = String(data: data, encoding: encoding) {
            return decoded
        }

        guard encoding == .utf8 else { return nil }

        for trim in 1...3 where data.count > trim {
            let head = data.prefix(data.count - trim)
            if let decoded = String(data: head, encoding: .utf8) {
                pendingTail = Data(data.suffix(trim))
                return decoded
            }
        }
        return nil
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
        private var pendingTail = Data()
        private var emitIndex = 0
        private var finished = false

        init(url: URL, encoding: String.Encoding, dialect: SqlDialect, countOnly: Bool) {
            self.url = url
            self.encoding = encoding
            self.dialect = dialect
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

            if rawData.isEmpty && pendingTail.isEmpty {
                emitTrailingStatement()
                finished = true
                closeFile()
                return
            }

            let isFinalChunk = rawData.isEmpty
            guard let chunk = SQLFileParser.decodeChunkOrCarryTail(
                rawData: rawData, pendingTail: &pendingTail, encoding: encoding
            ) else {
                throw DecompressionError.fileReadFailed(
                    "Failed to decode file with \(encoding.description) encoding"
                )
            }

            if isFinalChunk && !pendingTail.isEmpty {
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

                if nextChar == nil && SQLFileParser.needsLookahead(
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
                }

                if shouldDefer { break }
                if !didManuallyAdvance { i += 1 }
            }

            if i < bufLen {
                nsBuffer.deleteCharacters(in: NSRange(location: 0, length: i))
            } else {
                nsBuffer.setString("")
            }
        }

        private func emitTrailingStatement() {
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
