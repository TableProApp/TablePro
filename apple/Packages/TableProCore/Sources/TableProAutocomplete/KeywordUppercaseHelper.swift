import Foundation
import TableProSQLGrammar

public enum KeywordUppercaseHelper {
    public static func isWordBoundary(_ string: String) -> Bool {
        guard (string as NSString).length == 1, let ch = string.unicodeScalars.first else { return false }
        switch ch {
        case " ", "\t", "\n", "\r", "(", ")", ",", ";":
            return true
        default:
            return false
        }
    }

    static func isWordCharacter(_ ch: unichar) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) ||
        (ch >= 0x30 && ch <= 0x39) || ch == 0x5F
    }

    // Read from the start of the text with the session's grammar: a literal can open any distance back, and where it
    // ends is the engine's rule.
    static func isInsideProtectedContext(_ text: NSString, at position: Int, grammar: SQLLexicalGrammar) -> Bool {
        let length = text.length
        let runsExecutableComments = grammar.contains(.executableComments)
        var index = 0
        while index < position {
            // The server runs the body of `/*! ... */`, so it is code.
            if runsExecutableComments, let opener = SqlLexer.executableCommentOpenerLength(text, at: index, length: length) {
                index += opener
                continue
            }
            guard let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) else {
                index += 1
                continue
            }
            if SQLContextAnalyzer.holds(span, cursor: position) { return true }
            index = max(span.end, index + 1)
        }
        return false
    }

    // Nil when the word is not a keyword, sits in a comment, a literal or a quoted name, or is already in the target case.
    public static func keywordBeforePosition(
        _ text: NSString,
        at position: Int,
        uppercase: Bool = true,
        grammar: SQLLexicalGrammar
    ) -> (word: String, folded: String, range: NSRange)? {
        var wordStart = position
        while wordStart > 0 {
            let ch = text.character(at: wordStart - 1)
            guard isWordCharacter(ch) else { break }
            wordStart -= 1
        }

        let wordLength = position - wordStart
        guard wordLength > 0 else { return nil }

        let word = text.substring(with: NSRange(location: wordStart, length: wordLength))
        guard SQLKeywords.keywordSet.contains(word.lowercased()) else { return nil }
        guard !isInsideProtectedContext(text, at: wordStart, grammar: grammar) else { return nil }

        let folded = uppercase ? word.uppercased() : word.lowercased()
        guard folded != word else { return nil }

        return (word: word, folded: folded, range: NSRange(location: wordStart, length: wordLength))
    }
}
