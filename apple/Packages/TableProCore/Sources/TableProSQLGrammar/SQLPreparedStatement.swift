import Foundation

// What a PREPARE stores: MySQL's `PREPARE s FROM 'text'` or `FROM @variable`, and PostgreSQL's and DuckDB's
// `PREPARE q [(types)] AS statement`. A later EXECUTE runs it, so a gate reads it when it is prepared.
public enum SQLPreparedStatement {
    public enum Body: Equatable, Sendable {
        case text(at: Int)
        case statement(at: Int)
    }

    public static func body(in statement: String, grammar: SQLLexicalGrammar) -> Body? {
        let tokens = TSQLTokens.read(statement as NSString, grammar: grammar)
        guard tokens.first?.word == "PREPARE", tokens.count > 2 else { return nil }
        var cursor = 2
        if tokens[cursor].kind == .open {
            guard let close = tokens[(cursor + 1)...].firstIndex(where: { $0.kind == .close && $0.depth == 0 }) else {
                return nil
            }
            cursor = close + 1
        }
        guard tokens.indices.contains(cursor + 1) else { return nil }
        switch tokens[cursor].word {
        case "FROM": return .text(at: tokens[cursor + 1].location)
        case "AS": return .statement(at: tokens[cursor + 1].location)
        default: return nil
        }
    }
}
