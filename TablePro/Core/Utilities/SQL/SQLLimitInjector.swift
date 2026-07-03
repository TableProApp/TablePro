//
//  SQLLimitInjector.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum SQLLimitInjectionResult: Equatable {
    case injected(String)
    case alreadyLimited
    case notInjectable
}

enum SQLLimitInjector {
    static func inject(
        into sql: String,
        limit: Int,
        autoLimitStyle: AutoLimitStyle,
        lexicalDialect: SqlDialect
    ) -> SQLLimitInjectionResult {
        guard autoLimitStyle != .none, limit > 0 else { return .notInjectable }
        switch scan(sql, dialect: lexicalDialect, autoLimitStyle: autoLimitStyle) {
        case .insertAt(let index):
            guard autoLimitStyle == .limit else { return .notInjectable }
            var result = sql
            result.insert(contentsOf: " LIMIT \(limit)", at: String.Index(utf16Offset: index, in: result))
            return .injected(result)
        case .alreadyLimited:
            return .alreadyLimited
        case .notInjectable:
            return .notInjectable
        }
    }

    private enum ScanResult {
        case insertAt(Int)
        case alreadyLimited
        case notInjectable
    }

    private static let limitingKeywords: [String] = ["LIMIT", "FETCH"]
    private static let blockingKeywords: [String] = [
        "OFFSET", "FOR", "INTO", "LOCK", "FORMAT", "SETTINGS", "ALLOW", "FILTERING",
    ]

    private static let singleQuote = UInt16(UnicodeScalar("'").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)
    private static let semicolon = UInt16(UnicodeScalar(";").value)
    private static let dash = UInt16(UnicodeScalar("-").value)
    private static let slash = UInt16(UnicodeScalar("/").value)
    private static let star = UInt16(UnicodeScalar("*").value)
    private static let hash = UInt16(UnicodeScalar("#").value)
    private static let newline = UInt16(UnicodeScalar("\n").value)
    private static let backslash = UInt16(UnicodeScalar("\\").value)
    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)

    private static func scan(
        _ sql: String,
        dialect: SqlDialect,
        autoLimitStyle: AutoLimitStyle
    ) -> ScanResult {
        let buffer = sql as NSString
        let length = buffer.length
        guard length > 0 else { return .notInjectable }

        let dollarQuotesEnabled = dialect.supportsDollarQuotes
        let hashCommentsEnabled = dialect.supportsHashLineComments
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

            if !inString, hashCommentsEnabled, ch == hash {
                inLineComment = true
                i += 1
                continue
            }

            if isWhitespace(ch), !inString {
                i += 1
                continue
            }

            if sawStatementEnd { return .notInjectable }

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
                guard parenDepth >= 0 else { return .notInjectable }
                i += 1
                lastCodeEnd = i
                continue
            }

            if ch == semicolon, parenDepth == 0 {
                sawStatementEnd = true
                i += 1
                continue
            }

            if SqlDollarQuote.isIdentifierStart(ch), i == 0 || !SqlDollarQuote.isIdentifierContinuation(buffer.character(at: i - 1)) {
                var end = i + 1
                while end < length, SqlDollarQuote.isIdentifierPart(buffer.character(at: end)) { end += 1 }
                if parenDepth == 0 {
                    if matchesAny(limitingKeywords, in: buffer, start: i, end: end) {
                        return .alreadyLimited
                    }
                    if autoLimitStyle == .top, matchesKeyword("TOP", in: buffer, start: i, end: end) {
                        return .alreadyLimited
                    }
                    if matchesAny(blockingKeywords, in: buffer, start: i, end: end) {
                        return .notInjectable
                    }
                }
                i = end
                lastCodeEnd = end
                continue
            }

            i += 1
            lastCodeEnd = i
        }

        guard !inString, !inBlockComment, !inDollarQuote, parenDepth == 0, lastCodeEnd > 0 else {
            return .notInjectable
        }
        return .insertAt(lastCodeEnd)
    }

    private static func matchesAny(_ keywords: [String], in buffer: NSString, start: Int, end: Int) -> Bool {
        keywords.contains { matchesKeyword($0, in: buffer, start: start, end: end) }
    }

    private static func matchesKeyword(_ keyword: String, in buffer: NSString, start: Int, end: Int) -> Bool {
        let keywordBuffer = keyword as NSString
        guard end - start == keywordBuffer.length else { return false }
        for offset in 0..<keywordBuffer.length where uppercased(buffer.character(at: start + offset)) != keywordBuffer.character(at: offset) {
            return false
        }
        return true
    }

    private static func uppercased(_ ch: UInt16) -> UInt16 {
        (ch >= 0x61 && ch <= 0x7A) ? ch - 0x20 : ch
    }

    private static func isWhitespace(_ ch: UInt16) -> Bool {
        ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D
    }
}
