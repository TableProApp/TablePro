import Foundation

/// The row-limiting clauses of one statement, read only where the engine reads code: outside strings, comments and
/// dollar quotes, and at paren depth zero, so a CTE's or a subquery's LIMIT never counts for the whole statement.
public enum SQLStatementRowLimit {
    /// Whether the statement already bounds its own rows with `LIMIT` or `FETCH`. `countsTop` also takes `TOP`, for
    /// an engine that limits with `SELECT TOP n`; elsewhere `top` is an ordinary column name.
    public static func hasExplicitRowLimit(_ sql: String, countsTop: Bool, grammar: SQLLexicalGrammar) -> Bool {
        var found = false
        forEachTopLevelIdentifier(in: sql, grammar: grammar) { buffer, start, end in
            guard isLimitingKeyword(in: buffer, start: start, end: end, countsTop: countsTop, grammar: grammar) else {
                return false
            }
            found = true
            return true
        }
        return found
    }

    /// The UTF-16 offset of the first top-level row-limiting clause, so a caller splicing a clause
    /// onto the end of a statement can put it before that clause rather than after it.
    ///
    /// `TOP` is deliberately absent: it sits between SELECT and the column list, so it is not a
    /// trailing clause and splitting there would cut the statement in half.
    public static func firstRowLimitClauseOffset(_ sql: String, grammar: SQLLexicalGrammar) -> Int? {
        var offset: Int?
        forEachTopLevelIdentifier(in: sql, grammar: grammar) { buffer, start, end in
            guard startsRowLimitClause(in: buffer, start: start, end: end, grammar: grammar) else { return false }
            offset = start
            return true
        }
        return offset
    }

    /// Whether a compound term after the first is a bare `VALUES` list, as in `SELECT 1 UNION ALL VALUES (2)`. SQLite
    /// rejects a LIMIT after such a term, so a caller appending one leaves the statement as it is.
    public static func hasCompoundValuesTerm(_ sql: String, grammar: SQLLexicalGrammar) -> Bool {
        var found = false
        var isFirstWord = true
        forEachTopLevelIdentifier(in: sql, grammar: grammar) { buffer, start, end in
            defer { isFirstWord = false }
            guard !isFirstWord, matchesKeyword("VALUES", in: buffer, start: start, end: end) else { return false }
            found = true
            return true
        }
        return found
    }

    /// The statement with `LIMIT limit` after it, for a caller that has checked it states no limit of its own.
    public static func appendingLimit(_ limit: Int, to sql: String) -> String {
        "\(clauseHost(sql))\nLIMIT \(limit)"
    }

    /// The statement with the ANSI `FETCH FIRST limit ROWS ONLY` after it.
    public static func appendingFetchFirst(_ limit: Int, to sql: String) -> String {
        "\(clauseHost(sql))\nFETCH FIRST \(limit) ROWS ONLY"
    }

    /// The statement's first word, uppercased, past the blanks and comments `grammar` reads and a leading `(`, so a
    /// caller can tell a `SELECT` or `WITH` from a `VALUES` that refuses an appended LIMIT. Nil when no word starts it.
    public static func leadingKeyword(_ sql: String, grammar: SQLLexicalGrammar) -> String? {
        let keyword = SQLLeadingComments.leadingCodeKeyword(SQLLeadingComments.stripping(sql, grammar: grammar))
        return keyword.isEmpty ? nil : keyword
    }

    // The clause goes on a line of its own, so a trailing `--` comment cannot swallow it. A trailing `;` goes first,
    // or the clause would start a statement of its own.
    private static func clauseHost(_ sql: String) -> String {
        var statement = StatementBlank.trimming(sql)
        while statement.hasSuffix(";") {
            statement = StatementBlank.trimming(String(statement.dropLast()))
        }
        return statement
    }

    /// `OFFSET` is non-reserved in MySQL and MariaDB, so `SELECT offset, name FROM events` reaches
    /// here as a column name. What separates the clause from the identifier is what follows it: a
    /// row count, a placeholder, or `FIRST`/`NEXT` for the ANSI `FETCH` form.
    private static func startsRowLimitClause(
        in buffer: NSString,
        start: Int,
        end: Int,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        if matchesKeyword("FETCH", in: buffer, start: start, end: end) {
            let (wordStart, wordEnd) = nextWordRange(in: buffer, from: end, grammar: grammar)
            return matchesKeyword("FIRST", in: buffer, start: wordStart, end: wordEnd)
                || matchesKeyword("NEXT", in: buffer, start: wordStart, end: wordEnd)
        }
        guard matchesKeyword("LIMIT", in: buffer, start: start, end: end)
            || matchesKeyword("OFFSET", in: buffer, start: start, end: end)
        else {
            return false
        }
        let index = nextCodeIndex(in: buffer, from: end, grammar: grammar)
        guard index < buffer.length else { return false }
        let next = buffer.character(at: index)
        if next >= zero, next <= nine { return true }
        if next == question || next == colon || next == dollar || next == at { return true }
        let (wordStart, wordEnd) = nextWordRange(in: buffer, from: end, grammar: grammar)
        return matchesKeyword("ALL", in: buffer, start: wordStart, end: wordEnd)
    }

    private static func nextWordRange(in buffer: NSString, from index: Int, grammar: SQLLexicalGrammar) -> (Int, Int) {
        let start = nextCodeIndex(in: buffer, from: index, grammar: grammar)
        var end = start
        while end < buffer.length, SqlDollarQuote.isIdentifierPart(buffer.character(at: end)) { end += 1 }
        return (start, end)
    }

    // Past blanks and the comments `grammar` reads, so `FETCH /* page */ FIRST 10 ROWS ONLY` is still a clause.
    private static func nextCodeIndex(in buffer: NSString, from index: Int, grammar: SQLLexicalGrammar) -> Int {
        var index = index
        while index < buffer.length {
            if isSpace(buffer.character(at: index)) {
                index += 1
            } else if let span = SQLNonCodeSpan.span(at: index, in: buffer, grammar: grammar), span.kind.isComment {
                index = max(span.end, index + 1)
            } else {
                break
            }
        }
        return index
    }

    private static func isSpace(_ ch: UInt16) -> Bool {
        ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D
    }

    /// Walks `sql` and reports every identifier that sits outside a string, comment or dollar quote
    /// and at paren depth zero. The visitor returns true to stop the walk.
    private static func forEachTopLevelIdentifier(
        in sql: String,
        grammar: SQLLexicalGrammar,
        visit: (NSString, Int, Int) -> Bool
    ) {
        let buffer = sql as NSString
        let length = buffer.length
        guard length > 0 else { return }

        var parenDepth = 0
        var i = 0

        while i < length {
            let ch = buffer.character(at: i)

            if let span = SQLNonCodeSpan.span(at: i, in: buffer, grammar: grammar) {
                i = max(span.end, i + 1)
                continue
            }

            if ch == openParen {
                parenDepth += 1
                i += 1
                continue
            }

            if ch == closeParen {
                parenDepth -= 1
                i += 1
                continue
            }

            if SqlDollarQuote.isIdentifierStart(ch),
               i == 0 || !SqlDollarQuote.isIdentifierContinuation(buffer.character(at: i - 1)) {
                var end = i + 1
                while end < length, SqlDollarQuote.isIdentifierPart(buffer.character(at: end)) { end += 1 }
                if parenDepth == 0, visit(buffer, i, end) {
                    return
                }
                i = end
                continue
            }

            i += 1
        }
    }

    private static func isLimitingKeyword(
        in buffer: NSString,
        start: Int,
        end: Int,
        countsTop: Bool,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        if matchesKeyword("LIMIT", in: buffer, start: start, end: end) {
            return true
        }
        // SQLite does not reserve FETCH, so `SELECT * FROM fetch` names a table; only FETCH FIRST or NEXT limits rows.
        if matchesKeyword("FETCH", in: buffer, start: start, end: end) {
            return startsRowLimitClause(in: buffer, start: start, end: end, grammar: grammar)
        }
        return countsTop && matchesKeyword("TOP", in: buffer, start: start, end: end)
    }

    private static func matchesKeyword(_ keyword: String, in buffer: NSString, start: Int, end: Int) -> Bool {
        let keywordBuffer = keyword as NSString
        guard end - start == keywordBuffer.length else { return false }
        for offset in 0..<keywordBuffer.length
        where uppercased(buffer.character(at: start + offset)) != keywordBuffer.character(at: offset) {
            return false
        }
        return true
    }

    private static func uppercased(_ ch: UInt16) -> UInt16 {
        (ch >= 0x61 && ch <= 0x7A) ? ch - 0x20 : ch
    }

    private static let zero = UInt16(UnicodeScalar("0").value)
    private static let nine = UInt16(UnicodeScalar("9").value)
    private static let question = UInt16(UnicodeScalar("?").value)
    private static let colon = UInt16(UnicodeScalar(":").value)
    private static let at = UInt16(UnicodeScalar("@").value)
    private static let dollar = UInt16(UnicodeScalar("$").value)
    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)
}
