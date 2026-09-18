//
//  SQLLimitDetector.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum SQLLimitDetector {
    static func hasExplicitRowLimit(
        _ sql: String,
        autoLimitStyle: AutoLimitStyle,
        lexicalDialect: SqlDialect
    ) -> Bool {
        var found = false
        forEachTopLevelIdentifier(in: sql, lexicalDialect: lexicalDialect) { buffer, start, end in
            guard isLimitingKeyword(in: buffer, start: start, end: end, autoLimitStyle: autoLimitStyle) else {
                return false
            }
            found = true
            return true
        }
        return found
    }

    /// The UTF-16 offset of the first top-level row-limiting clause, so a caller splicing a clause
    /// onto the end of a statement can put it before that clause rather than after it.
    ///
    /// `TOP` is deliberately absent: it sits between SELECT and the column list, so it is not a
    /// trailing clause and splitting there would cut the statement in half.
    static func firstRowLimitClauseOffset(_ sql: String, lexicalDialect: SqlDialect) -> Int? {
        var offset: Int?
        forEachTopLevelIdentifier(in: sql, lexicalDialect: lexicalDialect) { buffer, start, end in
            guard startsRowLimitClause(in: buffer, start: start, end: end) else { return false }
            offset = start
            return true
        }
        return offset
    }

    /// `OFFSET` is non-reserved in MySQL and MariaDB, so `SELECT offset, name FROM events` reaches
    /// here as a column name. What separates the clause from the identifier is what follows it: a
    /// row count, a placeholder, or `FIRST`/`NEXT` for the ANSI `FETCH` form.
    private static func startsRowLimitClause(in buffer: NSString, start: Int, end: Int) -> Bool {
        if matchesKeyword("FETCH", in: buffer, start: start, end: end) {
            let (wordStart, wordEnd) = nextWordRange(in: buffer, from: end)
            return matchesKeyword("FIRST", in: buffer, start: wordStart, end: wordEnd)
                || matchesKeyword("NEXT", in: buffer, start: wordStart, end: wordEnd)
        }
        guard matchesKeyword("LIMIT", in: buffer, start: start, end: end)
            || matchesKeyword("OFFSET", in: buffer, start: start, end: end)
        else {
            return false
        }
        var index = end
        while index < buffer.length, isSpace(buffer.character(at: index)) { index += 1 }
        guard index < buffer.length else { return false }
        let next = buffer.character(at: index)
        if next >= zero, next <= nine { return true }
        if next == question || next == colon || next == dollar || next == at { return true }
        let (wordStart, wordEnd) = nextWordRange(in: buffer, from: end)
        return matchesKeyword("ALL", in: buffer, start: wordStart, end: wordEnd)
    }

    private static func nextWordRange(in buffer: NSString, from index: Int) -> (Int, Int) {
        var start = index
        while start < buffer.length, isSpace(buffer.character(at: start)) { start += 1 }
        var end = start
        while end < buffer.length, SqlDollarQuote.isIdentifierPart(buffer.character(at: end)) { end += 1 }
        return (start, end)
    }

    private static func isSpace(_ ch: UInt16) -> Bool {
        ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D
    }

    private static let zero = UInt16(UnicodeScalar("0").value)
    private static let nine = UInt16(UnicodeScalar("9").value)
    private static let question = UInt16(UnicodeScalar("?").value)
    private static let colon = UInt16(UnicodeScalar(":").value)
    private static let at = UInt16(UnicodeScalar("@").value)

    /// Walks `sql` and reports every identifier that sits outside a string, comment or dollar quote
    /// and at paren depth zero. The visitor returns true to stop the walk.
    private static func forEachTopLevelIdentifier(
        in sql: String,
        lexicalDialect: SqlDialect,
        visit: (NSString, Int, Int) -> Bool
    ) {
        let buffer = sql as NSString
        let length = buffer.length
        guard length > 0 else { return }

        let dollarQuotesEnabled = lexicalDialect.supportsDollarQuotes
        let hashCommentsEnabled = lexicalDialect.supportsHashLineComments
        var inString = false
        var stringChar: UInt16 = 0
        var inLineComment = false
        var inBlockComment = false
        var inDollarQuote = false
        var dollarTag = ""
        var parenDepth = 0
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
                    dollarTag = ""
                    continue
                }
                i += 1
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

            if inString, ch == backslash, i + 1 < length {
                i += 2
                continue
            }

            if ch == singleQuote || ch == doubleQuote || ch == backtick {
                if !inString {
                    inString = true
                    stringChar = ch
                } else if ch == stringChar {
                    if i + 1 < length, buffer.character(at: i + 1) == stringChar {
                        i += 2
                        continue
                    }
                    inString = false
                }
                i += 1
                continue
            }

            if inString {
                i += 1
                continue
            }

            if dollarQuotesEnabled, ch == dollar,
               case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(at: i, in: buffer, bufLen: length) {
                inDollarQuote = true
                dollarTag = tag
                i += openerLength
                continue
            }

            if ch == openParen {
                parenDepth += 1
                i += 1
                continue
            }

            if ch == closeParen {
                parenDepth -= 1
                i += 1
                continue
            }

            if SqlDollarQuote.isIdentifierStart(ch),
               i == 0 || !SqlDollarQuote.isIdentifierContinuation(buffer.character(at: i - 1)) {
                var end = i + 1
                while end < length, SqlDollarQuote.isIdentifierPart(buffer.character(at: end)) { end += 1 }
                if parenDepth == 0, visit(buffer, i, end) {
                    return
                }
                i = end
                continue
            }

            i += 1
        }
    }

    private static let limitingKeywords: [String] = ["LIMIT", "FETCH"]

    private static func isLimitingKeyword(
        in buffer: NSString,
        start: Int,
        end: Int,
        autoLimitStyle: AutoLimitStyle
    ) -> Bool {
        if limitingKeywords.contains(where: { matchesKeyword($0, in: buffer, start: start, end: end) }) {
            return true
        }
        return autoLimitStyle == .top && matchesKeyword("TOP", in: buffer, start: start, end: end)
    }

    private static func matchesKeyword(_ keyword: String, in buffer: NSString, start: Int, end: Int) -> Bool {
        let keywordBuffer = keyword as NSString
        guard end - start == keywordBuffer.length else { return false }
        for offset in 0..<keywordBuffer.length
        where uppercased(buffer.character(at: start + offset)) != keywordBuffer.character(at: offset) {
            return false
        }
        return true
    }

    private static func uppercased(_ ch: UInt16) -> UInt16 {
        (ch >= 0x61 && ch <= 0x7A) ? ch - 0x20 : ch
    }

    private static let singleQuote = UInt16(UnicodeScalar("'").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)
    private static let dash = UInt16(UnicodeScalar("-").value)
    private static let slash = UInt16(UnicodeScalar("/").value)
    private static let star = UInt16(UnicodeScalar("*").value)
    private static let hash = UInt16(UnicodeScalar("#").value)
    private static let newline = UInt16(UnicodeScalar("\n").value)
    private static let backslash = UInt16(UnicodeScalar("\\").value)
    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)
}
