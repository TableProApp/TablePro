import Foundation
import TableProSQLGrammar

// Cuts where the app's gates cut, so the driver never sends a piece they did not count. A PL/SQL block goes whole:
// the Dameng grammar does not delimit one, and a wrong cut sends the server a fragment.
public enum DamengScriptSplitter {
    private static let blockKeywords: Set<String> = [
        "BEGIN", "CASE", "DECLARE", "END", "IF", "LOOP"
    ]

    public static func statements(in script: String, backslashEscapes: Bool) -> [String] {
        let grammar = DamengGrammar.execution(backslashEscapes: backslashEscapes)
        guard !holdsBlock(script, grammar: grammar) else { return [script] }
        return SQLStatementScanner.allStatements(in: script, grammar: grammar)
    }

    private static func holdsBlock(_ script: String, grammar: SQLLexicalGrammar) -> Bool {
        SQLCodeProjection.code(of: script, grammar: grammar)
            .split { !($0.isLetter || $0.isNumber || $0 == "_") }
            .contains { blockKeywords.contains($0.uppercased()) }
    }
}
