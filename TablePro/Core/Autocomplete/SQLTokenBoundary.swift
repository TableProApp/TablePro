//
//  SQLTokenBoundary.swift
//  TablePro
//
//  Shared identifier-boundary rules for SQL completion. The context analyzer
//  and the completion adapter must agree on where the token under the cursor
//  starts, so both resolve it through this single implementation.
//

import Foundation

enum SQLTokenBoundary {
    private static let dot = UInt16(UnicodeScalar(".").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let underscore = UInt16(UnicodeScalar("_").value)

    static func isIdentifierChar(_ ch: UInt16) -> Bool {
        if (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) { return true }
        if ch >= 0x30 && ch <= 0x39 { return true }
        return ch == underscore
    }

    static func isTokenChar(_ ch: UInt16) -> Bool {
        isIdentifierChar(ch) || ch == backtick || ch == doubleQuote
    }

    /// Start of the identifier segment ending at `cursor`, scanning backward
    /// over identifier and quote characters and stopping at a dot, so a
    /// qualified name like `schema.tab` resolves to the segment after the dot.
    static func segmentStart(in text: NSString, endingAt cursor: Int) -> Int {
        let clamped = min(max(cursor, 0), text.length)
        var start = clamped
        var index = clamped - 1
        while index >= 0 {
            guard isTokenChar(text.character(at: index)) else { break }
            start = index
            index -= 1
        }
        return start
    }

    /// Replacement range for an accepted completion: the live segment under
    /// the cursor when a cursor is available, otherwise the stored range
    /// computed when the suggestion window opened.
    static func replacementRange(in text: NSString?, cursor: Int?, fallback: NSRange) -> NSRange {
        guard let text, let cursor, cursor >= 0, cursor <= text.length else { return fallback }
        let start = segmentStart(in: text, endingAt: cursor)
        return NSRange(location: start, length: cursor - start)
    }
}
