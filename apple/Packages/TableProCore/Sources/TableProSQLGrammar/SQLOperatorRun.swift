import Foundation

// PostgreSQL's operator rule, from its scanner: an operator is a run of operator characters, because a user can define
// one, so pgvector's `<#>` and PostGIS's `&&&` are single operators that no list holds.
public enum SQLOperatorRun {
    private static let plus = UInt16(UnicodeScalar("+").value)
    private static let operatorUnits: Set<UInt16> = Set("~!@#^&|`?+-*/%<>=".utf16)
    private static let signKeepers: Set<UInt16> = Set("~!@#^&|`?%".utf16)

    // Where the operator starting at `index` ends, or nil when the grammar has no such rule or `index` starts none.
    public static func end(at index: Int, in text: NSString, grammar: SQLLexicalGrammar) -> Int? {
        let length = text.length
        guard grammar.readsOperatorRuns, index >= 0, index < length,
              continuesRun(at: index, in: text, grammar: grammar)
        else {
            return nil
        }
        var end = index + 1
        while end < length, continuesRun(at: end, in: text, grammar: grammar) {
            end += 1
        }
        // `a=-1` is `=` and a sign: a run ends in `+` or `-` only when one of these characters is in it.
        let keepsSign = (index..<end).contains { signKeepers.contains(text.character(at: $0)) }
        if !keepsSign {
            while end - index > 1, isSign(text.character(at: end - 1)) {
                end -= 1
            }
        }
        return end
    }

    // A comment opener ends the run, as does a backtick where it quotes a name.
    private static func continuesRun(at index: Int, in text: NSString, grammar: SQLLexicalGrammar) -> Bool {
        operatorUnits.contains(text.character(at: index))
            && SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) == nil
    }

    private static func isSign(_ unit: UInt16) -> Bool {
        unit == plus || unit == SqlLexer.dash
    }
}

public extension SQLLexicalGrammar {
    // `E'...'` marks an engine that lexes with PostgreSQL's scanner, the one with operator runs.
    var readsOperatorRuns: Bool {
        contains(.escapeStringPrefix)
    }
}
