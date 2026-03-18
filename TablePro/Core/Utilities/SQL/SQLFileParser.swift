//
//  SQLFileParser.swift
//  TablePro
//
//  Streaming SQL file parser that splits SQL statements while handling
//  comments, string literals, and escape sequences.
//
//  Implementation: Uses a finite state machine to track parser context
//  (normal, in-comment, in-string) while processing files in 64KB chunks.
//  Handles edge cases where multi-character sequences (comments, escapes)
//  span chunk boundaries by deferring processing of special characters
//  until the next chunk arrives.
//
//  Performance: Uses NSString character(at:) for O(1) random access.
//  Swift String.Index operations on bridged NSStrings are O(n) per call,
//  which would make the inner loop O(n²) on large SQL dumps.
//

import Foundation
import os

/// SQL statement parser that handles comments, strings, and multi-line statements
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

    // MARK: - Unicode Constants (all BMP-safe for UTF-16)

    private static let kSemicolon: unichar = 0x3B     // ;
    private static let kSingleQuote: unichar = 0x27   // '
    private static let kDoubleQuote: unichar = 0x22   // "
    private static let kBacktick: unichar = 0x60      // `
    private static let kBackslash: unichar = 0x5C     // \
    private static let kDash: unichar = 0x2D          // -
    private static let kSlash: unichar = 0x2F         // /
    private static let kStar: unichar = 0x2A          // *
    private static let kNewline: unichar = 0x0A       // \n
    private static let kSpace: unichar = 0x20         // space
    private static let kTab: unichar = 0x09           // tab
    private static let kCarriageReturn: unichar = 0x0D // \r

    /// Characters that can start multi-character sequences (comments, escapes)
    /// and must not be processed at chunk boundaries without a lookahead character.
    nonisolated private static func isMultiCharSequenceStart(_ char: unichar) -> Bool {
        char == kDash || char == kSlash || char == kBackslash || char == kStar
    }

    /// Check if a unichar is whitespace (space, tab, newline, carriage return)
    nonisolated private static func isWhitespace(_ char: unichar) -> Bool {
        char == kSpace || char == kTab || char == kNewline || char == kCarriageReturn
    }

    private static func markContent(
        _ hasContent: Bool, _ startLine: Int, _ currentLine: Int
    ) -> (Bool, Int) {
        hasContent ? (true, startLine) : (true, currentLine)
    }

    /// Append a single UTF-16 code unit to an NSMutableString. O(1) amortized.
    private static func appendChar(_ char: unichar, to string: NSMutableString?) {
        guard let string else { return }
        var ch = char
        let single = NSString(characters: &ch, length: 1)
        string.append(single as String)
    }

    // MARK: - Public API

    /// Parse SQL file and return async stream of statements with line numbers
    /// - Parameters:
    ///   - url: File URL to parse
    ///   - encoding: Text encoding to use
    ///   - countOnly: When true, skips building statement strings for faster counting
    /// - Returns: AsyncStream of (statement, lineNumber) tuples
    func parseFile(
        url: URL,
        encoding: String.Encoding,
        countOnly: Bool = false
    ) async throws -> AsyncStream<(statement: String, lineNumber: Int)> {
        AsyncStream { continuation in
            Task.detached {
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
                    // nil when countOnly — skips all string building via optional chaining
                    let currentStatement: NSMutableString? = countOnly ? nil : NSMutableString()
                    var hasStatementContent = false
                    var currentLine = 1
                    var statementStartLine = 1
                    let nsBuffer = NSMutableString()
                    let chunkSize = 65_536

                    while true {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        let data = fileHandle.readData(ofLength: chunkSize)
                        if data.isEmpty { break }

                        guard let chunk = String(data: data, encoding: encoding) else {
                            Self.logger.error("Failed to decode chunk with encoding \(encoding.description)")
                            continuation.finish()
                            return
                        }

                        nsBuffer.append(chunk)
                        let bufLen = nsBuffer.length
                        var i = 0

                        while i < bufLen {
                            let char = nsBuffer.character(at: i)
                            let nextChar: unichar? = (i + 1 < bufLen) ? nsBuffer.character(at: i + 1) : nil

                            // Defer processing if at chunk boundary with a multi-char start
                            if nextChar == nil && Self.isMultiCharSequenceStart(char) {
                                break
                            }

                            if char == Self.kNewline { currentLine += 1 }
                            var didManuallyAdvance = false

                            switch state {
                            case .normal:
                                if char == Self.kDash && nextChar == Self.kDash {
                                    state = .inSingleLineComment
                                    if nextChar == Self.kNewline { currentLine += 1 }
                                    i += 2
                                    didManuallyAdvance = true
                                } else if char == Self.kSlash && nextChar == Self.kStar {
                                    state = .inMultiLineComment
                                    if nextChar == Self.kNewline { currentLine += 1 }
                                    i += 2
                                    didManuallyAdvance = true
                                } else if char == Self.kSingleQuote {
                                    state = .inSingleQuotedString
                                    (hasStatementContent, statementStartLine) = Self.markContent(hasStatementContent, statementStartLine, currentLine)
                                    Self.appendChar(char, to: currentStatement)
                                } else if char == Self.kDoubleQuote {
                                    state = .inDoubleQuotedString
                                    (hasStatementContent, statementStartLine) = Self.markContent(hasStatementContent, statementStartLine, currentLine)
                                    Self.appendChar(char, to: currentStatement)
                                } else if char == Self.kBacktick {
                                    state = .inBacktickQuotedString
                                    (hasStatementContent, statementStartLine) = Self.markContent(hasStatementContent, statementStartLine, currentLine)
                                    Self.appendChar(char, to: currentStatement)
                                } else if char == Self.kSemicolon {
                                    if hasStatementContent {
                                        let text = (currentStatement as NSString?)?
                                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                        continuation.yield((text, statementStartLine))
                                    }
                                    currentStatement?.setString("")
                                    hasStatementContent = false
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
                                if char == Self.kStar && nextChar == Self.kSlash {
                                    state = .normal
                                    if nextChar == Self.kNewline { currentLine += 1 }
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
                                          next == Self.kSingleQuote {
                                    Self.appendChar(next, to: currentStatement)
                                    if next == Self.kNewline { currentLine += 1 }
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
                                } else if char == Self.kDoubleQuote {
                                    state = .normal
                                }

                            case .inBacktickQuotedString:
                                Self.appendChar(char, to: currentStatement)
                                if char == Self.kBacktick {
                                    if let next = nextChar, next == Self.kBacktick {
                                        Self.appendChar(next, to: currentStatement)
                                        if next == Self.kNewline { currentLine += 1 }
                                        i += 2
                                        didManuallyAdvance = true
                                    } else {
                                        state = .normal
                                    }
                                }
                            }

                            if !didManuallyAdvance {
                                i += 1
                            }
                        }

                        // Keep unprocessed characters for next chunk
                        if i < bufLen {
                            nsBuffer.deleteCharacters(in: NSRange(location: 0, length: i))
                        } else {
                            nsBuffer.setString("")
                        }
                    }

                    // Add final statement if any
                    if hasStatementContent {
                        let text = (currentStatement as NSString?)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        continuation.yield((text, statementStartLine))
                    }

                    continuation.finish()
                } catch {
                    Self.logger.error("SQL file parsing failed: \(error.localizedDescription)")
                    Self.logger.error("Error details: \(error)")
                    continuation.finish()
                }
            }
        }
    }

    /// Count total statements in file (requires full file scan)
    /// - Parameters:
    ///   - url: File URL to parse
    ///   - encoding: Text encoding to use
    /// - Returns: Total number of statements
    func countStatements(url: URL, encoding: String.Encoding) async throws -> Int {
        var count = 0

        for await _ in try await parseFile(url: url, encoding: encoding, countOnly: true) {
            try Task.checkCancellation()
            count += 1
        }

        return count
    }
}
