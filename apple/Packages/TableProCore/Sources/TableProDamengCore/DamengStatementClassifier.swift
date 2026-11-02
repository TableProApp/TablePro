import Foundation
import TableProSQLGrammar

// A framing hint and the replay rule, never a verdict on what the user sees: the bridge converts whatever comes back.
public enum DamengStatementClassifier {
    private static let resultKeywords: Set<String> = [
        "DESC", "DESCRIBE", "EXPLAIN", "SELECT", "SHOW", "VALUES", "WITH"
    ]

    // Shorter than resultKeywords: WITH and VALUES can head a write, and a replayed write may apply twice.
    private static let readOnlyKeywords: Set<String> = [
        "DESC", "DESCRIBE", "EXPLAIN", "SELECT", "SHOW"
    ]

    private static let openParenthesis = UInt16(UnicodeScalar("(").value)
    private static let semicolon = UInt16(UnicodeScalar(";").value)

    public static func likelyReturnsRows(_ query: String) -> Bool {
        guard let keyword = firstKeyword(query) else { return false }
        return resultKeywords.contains(keyword)
    }

    public static func isReadOnly(_ query: String) -> Bool {
        guard let keyword = firstKeyword(query) else { return false }
        return readOnlyKeywords.contains(keyword)
    }

    private static func firstKeyword(_ query: String) -> String? {
        let text = query as NSString
        let grammar = DamengGrammar.execution(backslashEscapes: false)
        var index = 0
        while index < text.length {
            if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) {
                guard span.kind.isComment else { return nil }
                index = max(span.end, index + 1)
                continue
            }
            let blank = StatementBlank.blankLength(in: text, at: index)
            if blank > 0 {
                index += blank
                continue
            }
            let unit = text.character(at: index)
            guard unit == openParenthesis || unit == semicolon else { break }
            index += 1
        }
        guard index < text.length else { return nil }
        let keyword = text.substring(from: index).prefix { $0.isLetter || $0 == "_" }
        return keyword.isEmpty ? nil : keyword.uppercased()
    }
}
