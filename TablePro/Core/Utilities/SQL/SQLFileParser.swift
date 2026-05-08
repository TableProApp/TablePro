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

    private static func isIdentifierStart(_ ch: unichar) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || ch == 0x5F
    }

    private static func isIdentifierPart(_ ch: unichar) -> Bool {
        isIdentifierStart(ch) || (ch >= 0x30 && ch <= 0x39)
    }

    private enum DollarQuoteScan {
        case opener(length: Int, tag: String)
        case notOpener
        case needsMoreData
    }

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

    private static func scanDollarQuoteOpener(
        at pos: Int, in buffer: NSString, bufLen: Int
    ) -> DollarQuoteScan {
        var p = pos + 1
        while p < bufLen {
            let ch = buffer.character(at: p)
            if ch == kDollar {
                let tagLen = p - pos - 1
                if tagLen == 0 {
                    return .opener(length: 2, tag: "")
                }
                let firstChar = buffer.character(at: pos + 1)
                if !isIdentifierStart(firstChar) {
                    return .notOpener
                }
                let tag = buffer.substring(with: NSRange(location: pos + 1, length: tagLen))
                return .opener(length: tagLen + 2, tag: tag)
            }
            if !isIdentifierPart(ch) {
                return .notOpener
            }
            p += 1
        }
        return .needsMoreData
    }

    private static func matchesDollarClose(
        at pos: Int, tag: String, in buffer: NSString, bufLen: Int
    ) -> Bool {
        let closeLen = (tag as NSString).length + 2
        guard pos + closeLen <= bufLen else { return false }
        if buffer.character(at: pos) != kDollar { return false }
        if buffer.character(at: pos + closeLen - 1) != kDollar { return false }
        if tag.isEmpty { return true }
        let tagRange = NSRange(location: pos + 1, length: (tag as NSString).length)
        return buffer.substring(with: tagRange) == tag
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
        bufLen: Int,
        continuation: AsyncThrowingStream<(statement: String, lineNumber: Int), Error>.Continuation
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
            switch scanDollarQuoteOpener(at: i, in: nsBuffer, bufLen: bufLen) {
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
            yieldAndReset(&ctx, continuation: continuation)
            return StepResult(advanced: false, deferred: false)
        }

        if !ctx.isSingleCharDelimiter
            && matchesDelimiter(at: i, delimiter: ctx.currentDelimiter, in: nsBuffer, bufLen: bufLen) {
            yieldAndReset(&ctx, continuation: continuation)
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

    private static func yieldAndReset(
        _ ctx: inout ParserContext,
        continuation: AsyncThrowingStream<(statement: String, lineNumber: Int), Error>.Continuation
    ) {
        if ctx.hasStatementContent {
            let text = trimmedStatement(ctx)
            continuation.yield((text, ctx.statementStartLine))
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
                if matchesDollarClose(at: pos, tag: ctx.dollarTag, in: nsBuffer, bufLen: bufLen) {
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
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task.detached {
                do {
                    let fileHandle = try FileHandle(forReadingFrom: url)
                    defer {
                        do {
                            try fileHandle.close()
                        } catch {
                            Self.logger.warning("Failed to close file handle for \(url.path): \(error)")
                        }
                    }

                    var ctx = ParserContext(
                        dialect: dialect,
                        currentStatement: countOnly ? nil : NSMutableString()
                    )
                    let nsBuffer = NSMutableString()
                    let chunkSize = 65_536
                    var pendingTail = Data()

                    while true {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        let rawData = fileHandle.readData(ofLength: chunkSize)
                        if rawData.isEmpty && pendingTail.isEmpty { break }

                        let isFinalChunk = rawData.isEmpty
                        guard let chunk = Self.decodeChunkOrCarryTail(
                            rawData: rawData, pendingTail: &pendingTail, encoding: encoding
                        ) else {
                            Self.logger.error("Failed to decode chunk with encoding \(encoding.description)")
                            continuation.finish(throwing: DecompressionError.fileReadFailed(
                                "Failed to decode file with \(encoding.description) encoding"
                            ))
                            return
                        }

                        if isFinalChunk && !pendingTail.isEmpty {
                            Self.logger.error("Trailing bytes did not form a valid \(encoding.description) sequence at end of file")
                            continuation.finish(throwing: DecompressionError.fileReadFailed(
                                "Trailing bytes did not form a valid \(encoding.description) sequence at end of file"
                            ))
                            return
                        }

                        nsBuffer.append(chunk)
                        let bufLen = nsBuffer.length
                        var i = 0

                        while i < bufLen {
                            let char = nsBuffer.character(at: i)
                            let nextChar: unichar? = (i + 1 < bufLen) ? nsBuffer.character(at: i + 1) : nil

                            if nextChar == nil && Self.needsLookahead(
                                char,
                                state: ctx.state,
                                dialect: dialect,
                                delimiter: ctx.currentDelimiter,
                                isSingleCharDelimiter: ctx.isSingleCharDelimiter
                            ) {
                                break
                            }

                            if char == Self.kNewline { ctx.currentLine += 1 }
                            var didManuallyAdvance = false
                            var shouldDefer = false

                            switch ctx.state {
                            case .normal:
                                let result = Self.processNormalChar(
                                    &ctx, char: char, nextChar: nextChar,
                                    i: &i, nsBuffer: nsBuffer, bufLen: bufLen,
                                    continuation: continuation)
                                didManuallyAdvance = result.advanced
                                shouldDefer = result.deferred

                            case .inSingleLineComment:
                                if char == Self.kNewline {
                                    ctx.state = .normal
                                }

                            case .inMultiLineComment:
                                didManuallyAdvance = Self.processMultiLineComment(
                                    &ctx, char: char, nextChar: nextChar, i: &i)

                            case .inSingleQuotedString:
                                let result = Self.processQuotedString(
                                    &ctx, quoteChar: Self.kSingleQuote,
                                    i: &i, nsBuffer: nsBuffer, bufLen: bufLen)
                                didManuallyAdvance = result.advanced
                                shouldDefer = result.deferred

                            case .inDoubleQuotedString:
                                let result = Self.processQuotedString(
                                    &ctx, quoteChar: Self.kDoubleQuote,
                                    i: &i, nsBuffer: nsBuffer, bufLen: bufLen)
                                didManuallyAdvance = result.advanced
                                shouldDefer = result.deferred

                            case .inBacktickQuotedString:
                                let result = Self.processQuotedString(
                                    &ctx, quoteChar: Self.kBacktick,
                                    i: &i, nsBuffer: nsBuffer, bufLen: bufLen)
                                didManuallyAdvance = result.advanced
                                shouldDefer = result.deferred

                            case .inDollarQuote:
                                let result = Self.processDollarQuote(
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

                    if ctx.hasStatementContent {
                        let text = Self.trimmedStatement(ctx)
                        if Self.extractDelimiterChange(text) == nil {
                            continuation.yield((text, ctx.statementStartLine))
                        }
                    }

                    continuation.finish()
                } catch {
                    Self.logger.error("SQL file parsing failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
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
