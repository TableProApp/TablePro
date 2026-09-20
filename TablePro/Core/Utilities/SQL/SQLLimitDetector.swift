//
//  SQLLimitDetector.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

enum SQLLimitDetector {
    static func hasExplicitRowLimit(
        _ sql: String,
        autoLimitStyle: AutoLimitStyle,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        var found = false
        forEachTopLevelIdentifier(in: sql, grammar: grammar) { buffer, start, end in
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
    static func firstRowLimitClauseOffset(_ sql: String, grammar: SQLLexicalGrammar) -> Int? {
        var offset: Int?
        forEachTopLevelIdentifier(in: sql, grammar: grammar) { buffer, start, end in
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
        grammar: SQLLexicalGrammar,
        visit: (NSString, Int, Int) -> Bool
    ) {
        let buffer = sql as NSString
        let length = buffer.length
        guard length > 0 else { return }

        var parenDepth = 0
        var i = 0

        while i < length {
            let ch = buffer.character(at: i)

            if let span = SQLNonCodeSpan.span(at: i, in: buffer, grammar: grammar) {
                i = max(span.end, i + 1)
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

    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)
}
