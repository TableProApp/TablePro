import Foundation
import TableProSQLGrammar

public enum DamengPlaceholders {
    private static let questionMark = UInt16(UnicodeScalar("?").value)

    // One more piece than there are placeholders. A `?` in a literal, a quoted name or a comment stays in its piece.
    public static func pieces(of template: String, backslashEscapes: Bool) -> [String] {
        let grammar = DamengGrammar.execution(backslashEscapes: backslashEscapes)
        let text = template as NSString
        var pieces: [String] = []
        var start = 0
        var index = 0
        while index < text.length {
            if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) {
                index = max(span.end, index + 1)
                continue
            }
            if text.character(at: index) == questionMark {
                pieces.append(text.substring(with: NSRange(location: start, length: index - start)))
                start = index + 1
            }
            index += 1
        }
        pieces.append(text.substring(from: min(start, text.length)))
        return pieces
    }
}
