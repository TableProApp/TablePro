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

    private static let whereLength = "WHERE".utf16.count

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
        let verbs: [Int]
        switch first {
        case "UPDATE", "DELETE":
            verbs = [start]
        case "WITH":
            // A CTE may be named `delete` or `merge`, and on PostgreSQL its body may itself write. Every body is read
            // whether or not the list around it can be followed. When it cannot, every word at the statement's depth
            // is a candidate, which can only find a write that is not there.
            for body in commonTableExpressionBodies(in: tokens, depth: depth) {
                found += writes(inStatement: source.substring(with: body) as NSString, grammar: grammar)
            }
            verbs = mainStatement(in: tokens, with: start).map { [$0] }
                ?? tokens.indices.dropFirst(start + 1).filter { tokens[$0].depth == depth }
        case "ALTER":
            // ClickHouse writes rows with `ALTER TABLE t UPDATE ... WHERE` and `ALTER TABLE t DELETE WHERE`.
            guard tokens.indices.contains(start + 1), tokens[start + 1].word == "TABLE" else { return [] }
            let verb = tokens.indices.dropFirst(start + 2).first { index in
                let word = tokens[index].word
                return tokens[index].depth == depth && (word == "UPDATE" || word == "DELETE")
                    && tokens[index - 1].word != "ON"
            }
            verbs = verb.map { [$0] } ?? []
        default:
            verbs = []
        }
        let writes = verbs.compactMap { write(at: $0, in: tokens) }
        if !writes.isEmpty, !hasOwnWhere(tokens, depth: depth, in: source) {
            found += writes
        }
        return found
    }

    private static let bodyOpeners: Set<String> = ["AS", "MATERIALIZED"]

    // Found by scanning rather than by walking the list, so a body is read when a name is several tokens, as
    // `U&"gone"` is, or a SEARCH or CYCLE clause follows an earlier body.
    private static func commonTableExpressionBodies(in tokens: [TSQLTokens.Token], depth: Int) -> [NSRange] {
        tokens.indices.dropFirst().compactMap { index in
            guard tokens[index].depth == depth, bodyOpeners.contains(tokens[index - 1].word ?? ""),
                  let close = close(of: index, in: tokens)
            else { return nil }
            let inside = tokens[index].location + 1
            return NSRange(location: inside, length: tokens[close].location - inside)
        }
    }

    // Nil when no statement begins right after the last body: a name T-SQL reads as several words where the engine
    // reads one, as at a euro sign, or PostgreSQL's `SEARCH ... SET name` and `CYCLE ... USING name` after a body.
    private static func mainStatement(in tokens: [TSQLTokens.Token], with start: Int) -> Int? {
        var index = start + 1
        func word(_ expected: String) -> Bool {
            guard tokens.indices.contains(index), tokens[index].word == expected else { return false }
            index += 1
            return true
        }
        func parentheses() -> Bool {
            guard let close = close(of: index, in: tokens) else { return false }
            index = close + 1
            return true
        }
        _ = word("RECURSIVE")
        while tokens.indices.contains(index) {
            index += 1
            _ = parentheses()
            guard word("AS") else { return nil }
            _ = word("NOT")
            _ = word("MATERIALIZED")
            guard parentheses() else { return nil }
            guard tokens.indices.contains(index), tokens[index].kind == .comma else { break }
            index += 1
        }
        guard tokens.indices.contains(index), servedStatements.contains(tokens[index].word ?? "") else { return nil }
        return index
    }

    private static func close(of open: Int, in tokens: [TSQLTokens.Token]) -> Int? {
        guard tokens.indices.contains(open), tokens[open].kind == .open else { return nil }
        return tokens.indices.dropFirst(open + 1).first {
            tokens[$0].kind == .close && tokens[$0].depth == tokens[open].depth
        }
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
            tokens[index].depth == depth && tokens[index].word == "WHERE" && !isName(tokens, at: index, in: source)
        }
    }

    // The tokens end a word where T-SQL does. SQLite, PostgreSQL and MySQL read every character outside ASCII as part
    // of a name, a no-break space included, and MySQL lets a digit begin one. Taking a real filter for a name only
    // asks about a statement that had one.
    private static func isName(_ tokens: [TSQLTokens.Token], at index: Int, in source: NSString) -> Bool {
        guard index > 0 else { return false }
        let location = tokens[index].location
        let before = source.character(at: location - 1)
        if parameterPrefixes.contains(before) || SqlDollarQuote.isIdentifierContinuation(before) { return true }
        let end = location + whereLength
        if end < source.length, source.character(at: end) >= 0x80 { return true }
        // `t.where` is a column, and so is PostgreSQL's `RETURNING id AS where`.
        let previous = tokens[index - 1]
        if previous.word == "AS" { return true }
        return previous.kind == .other && source.character(at: previous.location) == period
    }
}
