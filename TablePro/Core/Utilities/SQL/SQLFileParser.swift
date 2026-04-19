//
//  SQLFileParser.swift
//  TablePro
//
//  Streaming SQL file parser that splits SQL statements while handling
//  comments, string literals, escape sequences, MySQL conditional comments,
//  DELIMITER commands, and hash comments.
//
//  Uses NSString character(at:) for O(1) random access.

import Foundation
import os

final class SQLFileParser: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLFileParser")

    // MARK: - Parser State

    private enum ParserState {
        case normal
        case inSingleLineComment
        case inMultiLineComment
        case inSingleQuotedString
        case inDoubleQuotedString
        case inBacktickQuotedString
    }

    // MARK: - Unicode Constants

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

    // State-aware chunk boundary deferral. Characters that need lookahead
    // in the current state must not be processed without nextChar available.
    nonisolated private static func needsLookahead(
        _ char: unichar, state: ParserState, delimiter: NSString, isSingleCharDelimiter: Bool
    ) -> Bool {
        switch state {
        case .normal:
            var result = char == kDash || char == kSlash || char == kBackslash || char == kStar
                || char == kSingleQuote || char == kDoubleQuote || char == kBacktick
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

    // MARK: - Delimiter Matching

    private static func matchesDelimiter(
        at position: Int, delimiter: NSString, in buffer: NSString, bufLen: Int
    ) -> Bool {
        let delimLen = delimiter.length
        guard position + delimLen <= bufLen else { return false }
        for j in 0..<delimLen {
            if buffer.character(at: position + j) != delimiter.character(at: j) {
                return false
            }
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

    // MARK: - Public API

    func parseFile(
        url: URL,
        encoding: String.Encoding,
        countOnly: Bool = false
    ) -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        AsyncThrowingStream { continuation in
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

                    var state: ParserState = .normal
                    let currentStatement: NSMutableString? = countOnly ? nil : NSMutableString()
                    var hasStatementContent = false
                    var currentLine = 1
                    var statementStartLine = 1
                    let nsBuffer = NSMutableString()
                    let chunkSize = 65_536

                    var isConditionalComment = false
                    var currentDelimiter: NSString = ";" as NSString
                    var isSingleCharDelimiter = true

                    while true {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        let data = fileHandle.readData(ofLength: chunkSize)
                        if data.isEmpty { break }

                        guard let chunk = String(data: data, encoding: encoding) else {
                            Self.logger.error("Failed to decode chunk with encoding \(encoding.description)")
                            continuation.finish(throwing: DecompressionError.fileReadFailed(
                                "Failed to decode file with \(encoding.description) encoding"
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
                                char, state: state,
                                delimiter: currentDelimiter,
                                isSingleCharDelimiter: isSingleCharDelimiter
                            ) {
                                break
                            }

                            if char == Self.kNewline { currentLine += 1 }
                            var didManuallyAdvance = false

                            switch state {
                            case .normal:
                                // DELIMITER is a client command terminated by newline, not by delimiter
                                if char == Self.kNewline && hasStatementContent {
                                    let text = (currentStatement as NSString?)?
                                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                    if let newDelim = Self.extractDelimiterChange(text) {
                                        currentDelimiter = newDelim as NSString
                                        isSingleCharDelimiter = currentDelimiter.length == 1
                                            && currentDelimiter.character(at: 0) == Self.kSemicolon
                                        currentStatement?.setString("")
                                        hasStatementContent = false
                                    }
                                }

                                if char == Self.kDash && nextChar == Self.kDash {
                                    state = .inSingleLineComment
                                    i += 2
                                    didManuallyAdvance = true
                                } else if char == Self.kHash {
                                    state = .inSingleLineComment
                                } else if char == Self.kSlash && nextChar == Self.kStar {
                                    let thirdChar: unichar? = (i + 2 < bufLen)
                                        ? nsBuffer.character(at: i + 2) : nil
                                    isConditionalComment = thirdChar == Self.kExclamation
                                    state = .inMultiLineComment
                                    if isConditionalComment {
                                        (hasStatementContent, statementStartLine) = Self.markContent(
                                            hasStatementContent, statementStartLine, currentLine)
                                        Self.appendChar(char, to: currentStatement)
                                        Self.appendChar(nextChar!, to: currentStatement)
                                    }
                                    i += 2
                                    didManuallyAdvance = true
                                } else if char == Self.kSingleQuote {
                                    if let next = nextChar, next == Self.kSingleQuote {
                                        (hasStatementContent, statementStartLine) = Self.markContent(
                                            hasStatementContent, statementStartLine, currentLine)
                                        Self.appendChar(char, to: currentStatement)
                                        Self.appendChar(next, to: currentStatement)
                                        i += 2
                                        didManuallyAdvance = true
                                    } else {
                                        state = .inSingleQuotedString
                                        (hasStatementContent, statementStartLine) = Self.markContent(
                                            hasStatementContent, statementStartLine, currentLine)
                                        Self.appendChar(char, to: currentStatement)
                                    }
                                } else if char == Self.kDoubleQuote {
                                    if let next = nextChar, next == Self.kDoubleQuote {
                                        (hasStatementContent, statementStartLine) = Self.markContent(
                                            hasStatementContent, statementStartLine, currentLine)
                                        Self.appendChar(char, to: currentStatement)
                                        Self.appendChar(next, to: currentStatement)
                                        i += 2
                                        didManuallyAdvance = true
                                    } else {
                                        state = .inDoubleQuotedString
                                        (hasStatementContent, statementStartLine) = Self.markContent(
                                            hasStatementContent, statementStartLine, currentLine)
                                        Self.appendChar(char, to: currentStatement)
                                    }
                                } else if char == Self.kBacktick {
                                    if let next = nextChar, next == Self.kBacktick {
                                        (hasStatementContent, statementStartLine) = Self.markContent(
                                            hasStatementContent, statementStartLine, currentLine)
                                        Self.appendChar(char, to: currentStatement)
                                        Self.appendChar(next, to: currentStatement)
                                        i += 2
                                        didManuallyAdvance = true
                                    } else {
                                        state = .inBacktickQuotedString
                                        (hasStatementContent, statementStartLine) = Self.markContent(
                                            hasStatementContent, statementStartLine, currentLine)
                                        Self.appendChar(char, to: currentStatement)
                                    }
                                } else if isSingleCharDelimiter && char == Self.kSemicolon {
                                    if hasStatementContent {
                                        let text = (currentStatement as NSString?)?
                                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                        continuation.yield((text, statementStartLine))
                                    }
                                    currentStatement?.setString("")
                                    hasStatementContent = false
                                } else if !isSingleCharDelimiter
                                    && Self.matchesDelimiter(
                                        at: i, delimiter: currentDelimiter, in: nsBuffer, bufLen: bufLen)
                                {
                                    if hasStatementContent {
                                        let text = (currentStatement as NSString?)?
                                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                        continuation.yield((text, statementStartLine))
                                    }
                                    currentStatement?.setString("")
                                    hasStatementContent = false
                                    i += currentDelimiter.length
                                    didManuallyAdvance = true
                                } else {
                                    if !hasStatementContent && !Self.isWhitespace(char) {
                                        statementStartLine = currentLine
                                        hasStatementContent = true
                                    }
                                    Self.appendChar(char, to: currentStatement)
                                }

                            case .inSingleLineComment:
                                if char == Self.kNewline {
                                    state = .normal
                                }

                            case .inMultiLineComment:
                                if isConditionalComment {
                                    Self.appendChar(char, to: currentStatement)
                                }
                                if char == Self.kStar && nextChar == Self.kSlash {
                                    if isConditionalComment {
                                        Self.appendChar(nextChar!, to: currentStatement)
                                    }
                                    state = .normal
                                    isConditionalComment = false
                                    i += 2
                                    didManuallyAdvance = true
                                }

                            case .inSingleQuotedString:
                                Self.appendChar(char, to: currentStatement)
                                if char == Self.kBackslash, let next = nextChar {
                                    Self.appendChar(next, to: currentStatement)
                                    if next == Self.kNewline { currentLine += 1 }
                                    i += 2
                                    didManuallyAdvance = true
                                } else if char == Self.kSingleQuote, let next = nextChar,
                                          next == Self.kSingleQuote
                                {
                                    Self.appendChar(next, to: currentStatement)
                                    i += 2
                                    didManuallyAdvance = true
                                } else if char == Self.kSingleQuote {
                                    state = .normal
                                }

                            case .inDoubleQuotedString:
                                Self.appendChar(char, to: currentStatement)
                                if char == Self.kBackslash, let next = nextChar {
                                    Self.appendChar(next, to: currentStatement)
                                    if next == Self.kNewline { currentLine += 1 }
                                    i += 2
                                    didManuallyAdvance = true
                                } else if char == Self.kDoubleQuote, let next = nextChar,
                                          next == Self.kDoubleQuote
                                {
                                    Self.appendChar(next, to: currentStatement)
                                    i += 2
                                    didManuallyAdvance = true
                                } else if char == Self.kDoubleQuote {
                                    state = .normal
                                }

                            case .inBacktickQuotedString:
                                Self.appendChar(char, to: currentStatement)
                                if char == Self.kBacktick, let next = nextChar,
                                   next == Self.kBacktick
                                {
                                    Self.appendChar(next, to: currentStatement)
                                    i += 2
                                    didManuallyAdvance = true
                                } else if char == Self.kBacktick {
                                    state = .normal
                                }
                            }

                            if !didManuallyAdvance {
                                i += 1
                            }
                        }

                        if i < bufLen {
                            nsBuffer.deleteCharacters(in: NSRange(location: 0, length: i))
                        } else {
                            nsBuffer.setString("")
                        }
                    }

                    if hasStatementContent {
                        let text = (currentStatement as NSString?)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if Self.extractDelimiterChange(text) == nil {
                            continuation.yield((text, statementStartLine))
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

    func countStatements(url: URL, encoding: String.Encoding) async throws -> Int {
        var count = 0

        for try await _ in parseFile(url: url, encoding: encoding, countOnly: true) {
            try Task.checkCancellation()
            count += 1
        }

        return count
    }
}
