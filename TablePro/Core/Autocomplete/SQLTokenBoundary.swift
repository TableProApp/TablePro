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

    /// Scalars outside ASCII that an identifier may contain. Every engine TablePro speaks accepts
    /// letters beyond ASCII in an identifier, quoted or (on MySQL, PostgreSQL and SQLite) bare, so
    /// an ASCII-only rule read `SELECT 名` as an empty token and accepting a suggestion inserted
    /// beside the typed text rather than replacing it. `$` is deliberately absent: it opens a
    /// MongoDB pipeline stage, whose own analyzer relies on the token starting there.
    private static let nonASCIIIdentifierScalars: CharacterSet = {
        var set = CharacterSet.letters
        set.formUnion(.decimalDigits)
        set.formUnion(.nonBaseCharacters)
        return set
    }()

    static func isIdentifierChar(_ ch: UInt16) -> Bool {
        if (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) { return true }
        if ch >= 0x30 && ch <= 0x39 { return true }
        return ch == underscore
    }

    static func isTokenChar(_ ch: UInt16) -> Bool {
        isIdentifierChar(ch) || ch == backtick || ch == doubleQuote
    }

    private static let identifierQuotes = CharacterSet(charactersIn: "`\"")

    /// The text a segment is matched on, which is not the text it replaces.
    ///
    /// ``segmentStart(in:endingAt:)`` deliberately keeps an opening quote inside the segment so an
    /// accepted completion overwrites it, but no candidate's filter text carries one, and the
    /// matcher needs every character of the pattern to appear in the target. Leaving the quote in
    /// dropped every candidate, keyword items included, so a quoted identifier completed nothing.
    static func matchText(of segment: String) -> String {
        segment.trimmingCharacters(in: identifierQuotes)
    }

    /// Start of the identifier segment ending at `cursor`, scanning backward
    /// over identifier and quote characters and stopping at a dot, so a
    /// qualified name like `schema.tab` resolves to the segment after the dot.
    ///
    /// The walk steps by composed character sequence rather than by UTF-16 unit, so a surrogate
    /// pair and a base character with its combining marks are each tested and consumed whole.
    /// ASCII input takes the single-unit path and behaves exactly as it did.
    static func segmentStart(in text: NSString, endingAt cursor: Int) -> Int {
        let clamped = min(max(cursor, 0), text.length)
        var start = clamped
        while start > 0 {
            let unit = text.character(at: start - 1)
            if unit < 0x80 {
                guard isTokenChar(unit) else { break }
                start -= 1
                continue
            }
            let sequence = text.rangeOfComposedCharacterSequence(at: start - 1)
            guard sequence.location + sequence.length <= start,
                  isNonASCIIIdentifierSequence(text.substring(with: sequence)) else { break }
            start = sequence.location
        }
        return start
    }

    private static func isNonASCIIIdentifierSequence(_ sequence: String) -> Bool {
        guard !sequence.isEmpty else { return false }
        return sequence.unicodeScalars.allSatisfy { nonASCIIIdentifierScalars.contains($0) }
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
