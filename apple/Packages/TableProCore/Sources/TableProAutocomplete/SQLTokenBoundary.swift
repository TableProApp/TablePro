import Foundation
import TableProSQLGrammar

// The context analyzer and the completion adapter must agree on where the token under the cursor starts.
public enum SQLTokenBoundary {
    private static let backtick = UInt16(UnicodeScalar("`").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)
    private static let underscore = UInt16(UnicodeScalar("_").value)

    // Letters beyond ASCII continue an identifier on every engine. `$` stays out: it opens a MongoDB pipeline stage,
    // whose analyzer needs the token to start there.
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

    private static let identifierQuotes = CharacterSet(charactersIn: "`\"[")

    // The segment keeps an opening quote so an accepted completion overwrites it, but no candidate's filter text
    // carries one, and the matcher needs every pattern character in the target.
    public static func matchText(of segment: String) -> String {
        segment.trimmingCharacters(in: identifierQuotes)
    }

    public static func segmentStart(in text: NSString, endingAt cursor: Int) -> Int {
        walkBack(in: text, from: min(max(cursor, 0), text.length), brackets: false)
    }

    public static func segmentStart(in text: NSString, endingAt cursor: Int, grammar: SQLLexicalGrammar) -> Int {
        segment(in: text, endingAt: cursor, grammar: grammar).start
    }

    // An editor that closes the pair leaves `[ord|]`. The quotes stay, so the segment starts after the opening one;
    // while the quote is open, the segment covers it.
    static func segment(
        in text: NSString,
        endingAt cursor: Int,
        grammar: SQLLexicalGrammar
    ) -> (start: Int, openQuote: Int?) {
        let caret = min(max(cursor, 0), text.length)
        let brackets = grammar.contains(.bracketQuotedIdentifiers)
        let start = walkBack(in: text, from: caret, brackets: brackets)
        guard start < caret,
              let close = closingQuote(for: text.character(at: start), brackets: brackets),
              !contains(close, in: text, from: start + 1, to: caret) else {
            return (start, nil)
        }
        let runEnd = identifierRun(in: text, from: caret)
        guard runEnd < text.length, text.character(at: runEnd) == close else { return (start, nil) }
        return (start + 1, start)
    }

    private static func walkBack(in text: NSString, from caret: Int, brackets: Bool) -> Int {
        var start = caret
        while start > 0 {
            let unit = text.character(at: start - 1)
            if unit < 0x80 {
                if brackets, unit == openBracket {
                    start -= 1
                    break
                }
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

    private static func identifierRun(in text: NSString, from caret: Int) -> Int {
        var end = caret
        while end < text.length {
            let unit = text.character(at: end)
            if unit < 0x80 {
                guard isIdentifierChar(unit) else { break }
                end += 1
                continue
            }
            let sequence = text.rangeOfComposedCharacterSequence(at: end)
            guard sequence.location == end,
                  isNonASCIIIdentifierSequence(text.substring(with: sequence)) else { break }
            end += sequence.length
        }
        return end
    }

    private static func closingQuote(for unit: UInt16, brackets: Bool) -> UInt16? {
        switch unit {
        case doubleQuote, backtick:
            return unit
        case openBracket where brackets:
            return closeBracket
        default:
            return nil
        }
    }

    private static func contains(_ unit: UInt16, in text: NSString, from start: Int, to end: Int) -> Bool {
        guard start < end else { return false }
        return (start..<end).contains { text.character(at: $0) == unit }
    }

    private static func isNonASCIIIdentifierSequence(_ sequence: String) -> Bool {
        guard !sequence.isEmpty else { return false }
        return sequence.unicodeScalars.allSatisfy { nonASCIIIdentifierScalars.contains($0) }
    }

    static func replacementRange(in text: NSString?, cursor: Int?, fallback: NSRange) -> NSRange {
        guard let text, let cursor, cursor >= 0, cursor <= text.length else { return fallback }
        let start = segmentStart(in: text, endingAt: cursor)
        return NSRange(location: start, length: cursor - start)
    }
}
