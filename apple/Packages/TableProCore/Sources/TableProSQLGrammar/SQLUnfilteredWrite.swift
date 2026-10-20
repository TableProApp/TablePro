import Foundation

// A WHERE in a comment, a literal, a quoted identifier or a subquery is not the statement's own.
public enum SQLUnfilteredWrite: Sendable, Equatable {
    case update
    case delete

    public static func writes(in sql: String, grammar: SQLLexicalGrammar) -> [SQLUnfilteredWrite] {
        SQLStatementScanner.executableStatements(in: sql, grammar: grammar).flatMap { statement in
            // On T-SQL a statement can begin inside another without a `;`.
            SQLUnterminatedStatements.runnable(in: statement.sql, grammar: grammar).flatMap { text in
                writes(inStatement: text as NSString, grammar: grammar)
            }
        }
    }

    private static let period = UInt16(UnicodeScalar(".").value)

    private static let servedStatements: Set<String> = ["SELECT", "INSERT", "UPDATE", "DELETE", "MERGE"]

    // `:where` and `$where` are bind parameters on SQLite.
    private static let parameterPrefixes: Set<UInt16> = [
        UInt16(UnicodeScalar(":").value), UInt16(UnicodeScalar("$").value),
    ]

    private static func writes(inStatement source: NSString, grammar: SQLLexicalGrammar) -> [SQLUnfilteredWrite] {
        let tokens = TSQLTokens.read(source, grammar: grammar)
        guard let start = tokens.firstIndex(where: { $0.kind != .open }), let first = tokens[start].word else {
            return []
        }
        let depth = tokens[start].depth
        var found: [SQLUnfilteredWrite] = []
        let verb: Int?
        switch first {
        case "UPDATE", "DELETE":
            verb = start
        case "WITH":
            // A CTE may be named `delete` or `merge`, and on PostgreSQL its body may itself write. A list that does
            // not parse is searched whole, which can only find a write that is not there.
            let list = commonTableExpressions(in: tokens, with: start)
            for body in list?.bodies ?? [] {
                found += writes(inStatement: source.substring(with: body) as NSString, grammar: grammar)
            }
            verb = tokens.indices.dropFirst(list?.main ?? start + 1).first { index in
                tokens[index].depth == depth && servedStatements.contains(tokens[index].word ?? "")
            }
        case "ALTER":
            // ClickHouse writes rows with `ALTER TABLE t UPDATE ... WHERE` and `ALTER TABLE t DELETE WHERE`.
            guard tokens.indices.contains(start + 1), tokens[start + 1].word == "TABLE" else { return [] }
            verb = tokens.indices.dropFirst(start + 2).first { index in
                let word = tokens[index].word
                return tokens[index].depth == depth && (word == "UPDATE" || word == "DELETE")
                    && tokens[index - 1].word != "ON"
            }
        default:
            verb = nil
        }
        if let verb, let write = write(at: verb, in: tokens), !hasOwnWhere(tokens, depth: depth, in: source) {
            found.append(write)
        }
        return found
    }

    private static func commonTableExpressions(
        in tokens: [TSQLTokens.Token],
        with start: Int
    ) -> (bodies: [NSRange], main: Int)? {
        let depth = tokens[start].depth
        var index = start + 1
        var bodies: [NSRange] = []
        func word(_ expected: String) -> Bool {
            guard tokens.indices.contains(index), tokens[index].word == expected else { return false }
            index += 1
            return true
        }
        func parentheses() -> NSRange? {
            guard tokens.indices.contains(index), tokens[index].kind == .open,
                  let close = tokens.indices.dropFirst(index + 1).first(where: {
                      tokens[$0].kind == .close && tokens[$0].depth == depth
                  })
            else { return nil }
            let inside = tokens[index].location + 1
            index = close + 1
            return NSRange(location: inside, length: tokens[close].location - inside)
        }
        _ = word("RECURSIVE")
        while tokens.indices.contains(index) {
            index += 1
            _ = parentheses()
            guard word("AS") else { return nil }
            _ = word("NOT")
            _ = word("MATERIALIZED")
            guard let body = parentheses() else { return nil }
            bodies.append(body)
            guard tokens.indices.contains(index), tokens[index].kind == .comma else { break }
            index += 1
        }
        return tokens.indices.contains(index) ? (bodies, index) : nil
    }

    private static func write(at index: Int, in tokens: [TSQLTokens.Token]) -> SQLUnfilteredWrite? {
        switch tokens[index].word {
        case "UPDATE":
            // T-SQL's `UPDATE STATISTICS t` writes no rows. A table named statistics is still updated with a SET.
            let next = tokens.indices.contains(index + 1) ? tokens[index + 1].word : nil
            let depth = tokens[index].depth
            let setsColumns = tokens.dropFirst(index + 1).contains { $0.depth == depth && $0.word == "SET" }
            return next == "STATISTICS" && !setsColumns ? nil : .update
        case "DELETE":
            return .delete
        default:
            return nil
        }
    }

    private static func hasOwnWhere(_ tokens: [TSQLTokens.Token], depth: Int, in source: NSString) -> Bool {
        tokens.indices.contains { index in
            guard tokens[index].depth == depth, tokens[index].word == "WHERE" else { return false }
            guard index > 0 else { return true }
            let location = tokens[index].location
            if location > 0, parameterPrefixes.contains(source.character(at: location - 1)) { return false }
            // `t.where` is a column.
            let previous = tokens[index - 1]
            return previous.kind != .other || source.character(at: previous.location) != period
        }
    }
}
