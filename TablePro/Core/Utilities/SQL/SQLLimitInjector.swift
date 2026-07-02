//
//  SQLLimitInjector.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum SQLLimitInjector {
    static func inject(
        into sql: String,
        limit: Int,
        autoLimitStyle: AutoLimitStyle,
        lexicalDialect: SqlDialect
    ) -> String? {
        guard autoLimitStyle == .limit, limit > 0 else { return nil }
        guard let insertionIndex = findInsertionIndex(in: sql, dialect: lexicalDialect) else { return nil }
        let buffer = sql as NSString
        let head = buffer.substring(to: insertionIndex)
        let tail = buffer.substring(from: insertionIndex)
        return "\(head) LIMIT \(limit)\(tail)"
    }

    private static let blockingKeywords: Set<String> = [
        "LIMIT", "OFFSET", "FETCH", "FOR", "INTO", "LOCK", "FORMAT", "SETTINGS",
    ]

    private static let singleQuote = UInt16(UnicodeScalar("'").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)
    private static let semicolon = UInt16(UnicodeScalar(";").value)
    private static let dash = UInt16(UnicodeScalar("-").value)
    private static let slash = UInt16(UnicodeScalar("/").value)
    private static let star = UInt16(UnicodeScalar("*").value)
    private static let newline = UInt16(UnicodeScalar("\n").value)
    private static let backslash = UInt16(UnicodeScalar("\\").value)
    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)

    private static func findInsertionIndex(in sql: String, dialect: SqlDialect) -> Int? {
        let buffer = sql as NSString
        let length = buffer.length
        guard length > 0 else { return nil }

        let dollarQuotesEnabled = dialect.supportsDollarQuotes
        var inString = false
        var stringChar: UInt16 = 0
        var inLineComment = false
        var inBlockComment = false
        var inDollarQuote = false
        var dollarTag = ""
        var parenDepth = 0
        var lastCodeEnd = 0
        var sawStatementEnd = false
        var i = 0

        while i < length {
            let ch = buffer.character(at: i)

            if inLineComment {
                if ch == newline { inLineComment = false }
                i += 1
                continue
            }

            if inBlockComment {
                if ch == star, i + 1 < length, buffer.character(at: i + 1) == slash {
                    inBlockComment = false
                    i += 2
                    continue
                }
                i += 1
                continue
            }

            if inDollarQuote {
                if ch == dollar, SqlDollarQuote.matchesClose(at: i, tag: dollarTag, in: buffer, bufLen: length) {
                    inDollarQuote = false
                    i += (dollarTag as NSString).length + 2
                    lastCodeEnd = i
                    dollarTag = ""
                    continue
                }
                i += 1
                lastCodeEnd = i
                continue
            }

            if !inString, ch == dash, i + 1 < length, buffer.character(at: i + 1) == dash {
                inLineComment = true
                i += 2
                continue
            }

            if !inString, ch == slash, i + 1 < length, buffer.character(at: i + 1) == star {
                inBlockComment = true
                i += 2
                continue
            }

            if isWhitespace(ch), !inString {
                i += 1
                continue
            }

            if sawStatementEnd { return nil }

            if inString, ch == backslash, i + 1 < length {
                i += 2
                lastCodeEnd = i
                continue
            }

            if ch == singleQuote || ch == doubleQuote || ch == backtick {
                if !inString {
                    inString = true
                    stringChar = ch
                } else if ch == stringChar {
                    if i + 1 < length, buffer.character(at: i + 1) == stringChar {
                        i += 2
                        lastCodeEnd = i
                        continue
                    }
                    inString = false
                }
                i += 1
                lastCodeEnd = i
                continue
            }

            if inString {
                i += 1
                lastCodeEnd = i
                continue
            }

            if dollarQuotesEnabled, ch == dollar,
               case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(at: i, in: buffer, bufLen: length) {
                inDollarQuote = true
                dollarTag = tag
                i += openerLength
                lastCodeEnd = i
                continue
            }

            if ch == openParen {
                parenDepth += 1
                i += 1
                lastCodeEnd = i
                continue
            }

            if ch == closeParen {
                parenDepth -= 1
                guard parenDepth >= 0 else { return nil }
                i += 1
                lastCodeEnd = i
                continue
            }

            if ch == semicolon, parenDepth == 0 {
                sawStatementEnd = true
                i += 1
                continue
            }

            if isWordStart(ch), i == 0 || !isWordPart(buffer.character(at: i - 1)) {
                var end = i + 1
                while end < length, isWordPart(buffer.character(at: end)) { end += 1 }
                if parenDepth == 0 {
                    let word = buffer.substring(with: NSRange(location: i, length: end - i)).uppercased()
                    if blockingKeywords.contains(word) { return nil }
                }
                i = end
                lastCodeEnd = end
                continue
            }

            i += 1
            lastCodeEnd = i
        }

        guard !inString, !inBlockComment, !inDollarQuote, parenDepth == 0, lastCodeEnd > 0 else { return nil }
        return lastCodeEnd
    }

    private static func isWhitespace(_ ch: UInt16) -> Bool {
        ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D
    }

    private static func isWordStart(_ ch: UInt16) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || ch == 0x5F
    }

    private static func isWordPart(_ ch: UInt16) -> Bool {
        isWordStart(ch) || (ch >= 0x30 && ch <= 0x39)
    }
}
