import Foundation

// A WHERE in a comment, a literal, a quoted identifier or a subquery is not the statement's own.
public enum SQLUnfilteredWrite: Sendable, Equatable {
    case update
    case delete

    public static func writes(in sql: String, grammar: SQLLexicalGrammar) -> [SQLUnfilteredWrite] {
        writes(in: sql, grammar: grammar, readsRecordIds: false)
    }

    static func writes(in sql: String, grammar: SQLLexicalGrammar, readsRecordIds: Bool) -> [SQLUnfilteredWrite] {
        SQLStatementScanner.executableStatements(in: sql, grammar: grammar).flatMap { statement in
            // On T-SQL a statement can begin inside another without a `;`.
            SQLUnterminatedStatements.runnable(in: statement.sql, grammar: grammar).flatMap { text in
                writes(inStatement: text as NSString, grammar: grammar, readsRecordIds: readsRecordIds)
            }
        }
    }

    // SurrealQL's `DELETE person:tobie` has no WHERE and removes the one record its id names.
    private static func writes(
        inStatement source: NSString,
        grammar: SQLLexicalGrammar,
        readsRecordIds: Bool
    ) -> [SQLUnfilteredWrite] {
        if readsRecordIds, SurrealRecordDelete.namesOneRecord(source, grammar: grammar) { return [] }
        return writes(inStatement: source, grammar: grammar)
    }

    private static let period = UInt16(UnicodeScalar(".").value)

    private static let whereLength = "WHERE".utf16.count

    private static let servedStatements: Set<String> = ["SELECT", "INSERT", "UPDATE", "DELETE", "MERGE"]

    // `:where`, `$where`, `@where` and `#where` are bind parameters on SQLite, and `@where` a user variable on MySQL.
    private static let parameterPrefixes: Set<UInt16> = [
        UInt16(UnicodeScalar(":").value), UInt16(UnicodeScalar("$").value), UInt16(UnicodeScalar("@").value),
        SqlLexer.hash,
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

// SurrealDB 2.3 and 3.0 (`parse_delete_stmt`) read `DELETE [FROM] [ONLY]`, the targets, then WITH, WHERE, RETURN,
// TIMEOUT, PARALLEL and EXPLAIN. A `table:key` target with the key right after the colon names one record
// (`parse_record_id_or_range`); a `..` or `>` after the key makes it a range. A table, a parameter, a subquery, an
// edge (`t:a->e`), a field (`t:a.f`), a second target or a key this does not read is every row.
private struct SurrealRecordDelete {
    private static let clauses: Set<String> = ["WITH", "WHERE", "RETURN", "TIMEOUT", "PARALLEL", "EXPLAIN"]
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let openBrace = UInt16(UnicodeScalar("{").value)
    private static let closers: [UInt16: UInt16] = [
        SqlLexer.openParen: SqlLexer.closeParen,
        openBracket: UInt16(UnicodeScalar("]").value),
        openBrace: UInt16(UnicodeScalar("}").value),
    ]
    private static let closing = Set(closers.values)
    private static let colon = UInt16(UnicodeScalar(":").value)
    private static let period = UInt16(UnicodeScalar(".").value)
    private static let plus = UInt16(UnicodeScalar("+").value)
    private static let smallU = UInt16(UnicodeScalar("u").value)

    let text: NSString
    let grammar: SQLLexicalGrammar
    var index = 0

    static func namesOneRecord(_ text: NSString, grammar: SQLLexicalGrammar) -> Bool {
        var reader = SurrealRecordDelete(text: text, grammar: grammar)
        return reader.readsOneRecordDelete()
    }

    private mutating func readsOneRecordDelete() -> Bool {
        skipBlanks()
        guard word() == "DELETE" else { return false }
        skipKeyword("FROM")
        skipKeyword("ONLY")
        skipBlanks()
        guard readsName(), peek() == Self.colon else { return false }
        index += 1
        guard readsKey() else { return false }
        skipBlanks()
        guard let next = peek() else { return true }
        if next == SqlLexer.semicolon {
            index += 1
            skipBlanks()
            return peek() == nil
        }
        return word().map(Self.clauses.contains) == true
    }

    // `parse_record_id_key`: an integer with or without a sign, a name, a `u"..."` UUID, or an array or object. A
    // generated key such as `rand()` is left unread.
    private mutating func readsKey() -> Bool {
        guard let first = peek() else { return false }
        if first == Self.plus || first == SqlLexer.dash {
            index += 1
            let digits = index
            while let next = peek(), next >= 0x30, next <= 0x39 {
                index += 1
            }
            return index > digits
        }
        if first == Self.smallU, index + 1 < text.length,
           [SqlLexer.singleQuote, SqlLexer.doubleQuote].contains(text.character(at: index + 1)) {
            return readsQuoted(at: index + 1)
        }
        if first == Self.openBracket || first == Self.openBrace {
            return readsValues()
        }
        return readsName()
    }

    // A string is a value, so `person:"tobie"` is not a key SurrealDB parses.
    private mutating func readsName() -> Bool {
        if let first = peek(), first == SqlLexer.backtick || first == SqlLexer.openAngleQuote {
            return readsQuoted(at: index)
        }
        return word() != nil
    }

    private mutating func readsQuoted(at start: Int) -> Bool {
        guard let span = SQLNonCodeSpan.span(at: start, in: text, grammar: grammar), span.kind == .quoted,
              span.isTerminated
        else { return false }
        index = span.end
        return true
    }

    // Whatever an array or object key holds, it is one key. A `..` inside is still read as a range.
    private mutating func readsValues() -> Bool {
        var expected: [UInt16] = []
        while let next = peek() {
            if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) {
                index = max(span.end, index + 1)
                continue
            }
            if let closer = Self.closers[next] {
                expected.append(closer)
            } else if Self.closing.contains(next) {
                guard expected.popLast() == next else { return false }
                if expected.isEmpty {
                    index += 1
                    return true
                }
            } else if next == Self.period, index + 1 < text.length, text.character(at: index + 1) == Self.period {
                return false
            }
            index += 1
        }
        return false
    }

    private mutating func skipKeyword(_ keyword: String) {
        skipBlanks()
        let start = index
        if word() != keyword { index = start }
    }

    private mutating func skipBlanks() {
        while index < text.length {
            let blank = StatementBlank.blankLength(in: text, at: index)
            if blank > 0 {
                index += blank
            } else if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar), span.kind.isComment {
                index = max(span.end, index + 1)
            } else {
                return
            }
        }
    }

    private mutating func word() -> String? {
        let start = index
        while let next = peek(), SqlDollarQuote.isIdentifierPart(next) {
            index += 1
        }
        guard index > start else { return nil }
        return text.substring(with: NSRange(location: start, length: index - start)).uppercased()
    }

    private func peek() -> UInt16? {
        index < text.length ? text.character(at: index) : nil
    }
}
