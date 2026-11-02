import Foundation

// The parts of a statement that opens with a WITH list: each CTE body and the statement the list belongs to. Nil when
// the text after WITH is not a list this reader knows, which a gate counts as a write.
//
// A CTE is `name [(columns)] AS [NOT] [MATERIALIZED] (body)`, with PostgreSQL's SEARCH and CYCLE clauses after it, or
// ClickHouse's `expression AS alias`.
public enum SQLCommonTableExpressions {
    public struct Reading: Equatable, Sendable {
        public let bodies: [NSRange]
        public let mainStatement: Int
    }

    private static let searchClauseWords: Set<String> = ["SEARCH", "CYCLE"]

    public static func read(_ statement: String, grammar: SQLLexicalGrammar) -> Reading? {
        let text = statement as NSString
        let tokens = TSQLTokens.read(text, grammar: grammar)
        guard let with = tokens.firstIndex(where: { $0.kind != .open }), tokens[with].word == "WITH" else { return nil }
        let depth = tokens[with].depth
        var index = with + 1
        if tokens.indices.contains(index), tokens[index].word == "RECURSIVE" { index += 1 }
        var bodies: [NSRange] = []

        func closing(_ open: Int) -> Int? {
            tokens[(open + 1)...].firstIndex { $0.kind == .close && $0.depth == tokens[open].depth }
        }

        while true {
            guard let alias = tokens[index...].firstIndex(where: { $0.depth == depth && $0.word == "AS" }),
                  alias > index, tokens.indices.contains(alias + 1)
            else { return nil }
            var cursor = alias + 1
            for modifier in ["NOT", "MATERIALIZED"]
            where tokens.indices.contains(cursor) && tokens[cursor].word == modifier {
                cursor += 1
            }
            guard tokens.indices.contains(cursor) else { return nil }
            let hasBody = tokens[cursor].kind == .open
            if hasBody {
                guard isNamed(tokens[index..<alias]), let close = closing(cursor) else { return nil }
                let start = tokens[cursor].location + 1
                bodies.append(NSRange(location: start, length: tokens[close].location - start))
                cursor = close + 1
                while tokens.indices.contains(cursor), tokens[cursor].word.map(searchClauseWords.contains) == true {
                    cursor = endOfSearchClause(from: cursor, depth: depth, tokens: tokens)
                }
            } else {
                guard cursor == alias + 1, isAlias(tokens[cursor]) else { return nil }
                cursor += 1
            }
            guard tokens.indices.contains(cursor) else { return nil }
            if tokens[cursor].kind == .comma, tokens[cursor].depth == depth {
                index = cursor + 1
                guard tokens.indices.contains(index) else { return nil }
                continue
            }
            // `(SELECT 1) UNION (SELECT 2)` may follow a body, never an alias.
            guard tokens[cursor].word != nil || (hasBody && tokens[cursor].kind == .open) else { return nil }
            return Reading(bodies: bodies, mainStatement: tokens[cursor].location)
        }
    }

    // A CTE's name, quoted or not, and its column list.
    private static func isNamed(_ head: ArraySlice<TSQLTokens.Token>) -> Bool {
        guard let name = head.first, isAlias(name) else { return false }
        let columns = head.dropFirst()
        guard let open = columns.first else { return true }
        return open.kind == .open && columns.last?.kind == .close && columns.last?.depth == open.depth
    }

    private static func isAlias(_ token: TSQLTokens.Token) -> Bool {
        switch token.kind {
        case .word, .name, .quoted: return true
        default: return false
        }
    }

    // `SEARCH DEPTH FIRST BY a, b SET ord` ends at the name after SET, and `CYCLE a, b SET seen [TO x DEFAULT y]
    // USING path` at the name after USING; the commas between them list columns.
    private static func endOfSearchClause(from start: Int, depth: Int, tokens: [TSQLTokens.Token]) -> Int {
        let last = tokens[start].word == "SEARCH" ? "SET" : "USING"
        guard let word = tokens[(start + 1)...].firstIndex(where: { $0.depth == depth && $0.word == last }) else {
            return tokens.count
        }
        return word + 2
    }
}
