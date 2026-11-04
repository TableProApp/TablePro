import Foundation
import TableProSQLGrammar
import Testing

struct SQLStatementRowLimitTests {
    private static func grammar(_ typeId: String) -> SQLLexicalGrammar {
        SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
    }

    private static let standard = SQLLexicalGrammar.ansi
    private static let postgreSQL = grammar("PostgreSQL")
    private static let mySQL = grammar("MySQL")
    private static let sqlite = grammar("SQLite")

    private func hasLimit(_ sql: String, countsTop: Bool = false, grammar: SQLLexicalGrammar = standard) -> Bool {
        SQLStatementRowLimit.hasExplicitRowLimit(sql, countsTop: countsTop, grammar: grammar)
    }

    private func clauseOffset(_ sql: String, grammar: SQLLexicalGrammar = postgreSQL) -> Int? {
        SQLStatementRowLimit.firstRowLimitClauseOffset(sql, grammar: grammar)
    }

    // MARK: - Explicit row limit

    @Test("A bare SELECT has no explicit row limit")
    func bareSelect() {
        #expect(!hasLimit("SELECT * FROM users"))
    }

    @Test("A SELECT ending in ORDER BY has no explicit row limit")
    func orderByIsNotALimit() {
        #expect(!hasLimit("SELECT * FROM alert_events ORDER BY alert_time"))
        #expect(!hasLimit("SELECT *\nFROM alert_events ORDER BY alert_time"))
        #expect(!hasLimit("SELECT * FROM t WHERE created_at >= '2026-01-01' ORDER BY id DESC"))
        #expect(!hasLimit("SELECT * FROM t ORDER BY a, b DESC"))
    }

    @Test("Detects a top-level LIMIT")
    func topLevelLimit() {
        #expect(hasLimit("SELECT * FROM users LIMIT 10"))
        #expect(hasLimit("select * from users limit 10 offset 5"))
        #expect(hasLimit("SELECT * FROM t ORDER BY id DESC LIMIT 10"))
    }

    @Test("Detects FETCH FIRST")
    func fetchFirst() {
        #expect(hasLimit("SELECT * FROM t FETCH FIRST 5 ROWS ONLY"))
    }

    @Test("A table or column named fetch is no FETCH clause")
    func fetchAsIdentifier() {
        #expect(!hasLimit("SELECT * FROM fetch", grammar: Self.sqlite))
        #expect(!hasLimit("SELECT fetch FROM jobs ORDER BY fetch", grammar: Self.sqlite))
        #expect(hasLimit("SELECT * FROM fetch FETCH NEXT 5 ROWS ONLY"))
    }

    @Test("A comment between FETCH and FIRST still makes a FETCH clause")
    func fetchWithComment() {
        #expect(hasLimit("SELECT * FROM events FETCH /* page */ FIRST 5000 ROWS ONLY", grammar: Self.postgreSQL))
        #expect(hasLimit("SELECT * FROM events FETCH -- page\nNEXT 10 ROWS ONLY", grammar: Self.postgreSQL))
        #expect(clauseOffset("SELECT * FROM events LIMIT /* n */ 10") == 21)
    }

    @Test("A VALUES list after a compound operator is a compound VALUES term", arguments: [
        ("SELECT 1 UNION ALL VALUES (2)", true),
        ("SELECT 1 union values (2), (3)", true),
        ("SELECT * FROM t WHERE id IN (VALUES (1), (2))", false),
        ("VALUES (1), (2)", false),
        ("SELECT 'VALUES' FROM t -- VALUES", false)
    ])
    func compoundValuesTerm(sql: String, expected: Bool) {
        #expect(SQLStatementRowLimit.hasCompoundValuesTerm(sql, grammar: Self.sqlite) == expected)
    }

    // A caller appending a LIMIT takes the scanner's statement, which ends before its terminator and any comment
    // after it: `SELECT 1; -- note` with a LIMIT after the comment would be a second, invalid statement.
    @Test("The scanned statement leaves out a comment after its terminator")
    func scannedStatementTakesTheLimit() {
        let statements = SQLStatementScanner.allStatements(in: "SELECT * FROM events; -- note", grammar: Self.sqlite)
        #expect(statements == ["SELECT * FROM events"])
        #expect(SQLStatementRowLimit.appendingLimit(3, to: statements[0]) == "SELECT * FROM events\nLIMIT 3")
    }

    @Test("Counts TOP only when asked to")
    func topOnlyWhenCounted() {
        #expect(hasLimit("SELECT TOP 5 * FROM t", countsTop: true))
        #expect(!hasLimit("SELECT TOP 5 * FROM t"))
        #expect(!hasLimit("SELECT top FROM quotas"))
    }

    @Test("A top-level OFFSET without LIMIT is not an explicit row limit")
    func offsetWithoutLimit() {
        #expect(!hasLimit("SELECT * FROM users OFFSET 5"))
    }

    @Test("An inner LIMIT in a CTE or subquery does not bound the outer statement")
    func innerLimitDoesNotCount() {
        #expect(!hasLimit("WITH cte AS (SELECT * FROM t LIMIT 5) SELECT * FROM cte"))
        #expect(!hasLimit("SELECT * FROM (SELECT * FROM t LIMIT 5) sub"))
        #expect(!hasLimit("(SELECT a FROM t1 LIMIT 5) UNION (SELECT b FROM t2 LIMIT 5)"))
    }

    @Test("Detects a LIMIT that applies to a whole UNION")
    func unionLimit() {
        #expect(hasLimit("SELECT a FROM t1 UNION SELECT b FROM t2 LIMIT 5"))
        #expect(!hasLimit("SELECT a FROM t1 UNION ALL SELECT b FROM t2"))
    }

    @Test("Ignores LIMIT-like text inside comments")
    func ignoresComments() {
        #expect(!hasLimit("SELECT * FROM t -- fetch it all"))
        #expect(!hasLimit("SELECT * FROM t /* LIMIT 9 */"))
        #expect(!hasLimit("SELECT * FROM t # see LIMIT docs", grammar: Self.mySQL))
    }

    @Test("Ignores LIMIT-like text inside string literals")
    func ignoresStringLiterals() {
        #expect(!hasLimit("SELECT * FROM t WHERE note = 'no LIMIT here'"))
    }

    @Test("Ignores LIMIT inside dollar-quoted bodies for PostgreSQL")
    func ignoresDollarQuotedBodies() {
        #expect(!hasLimit("SELECT $tag$LIMIT 5$tag$ FROM t", grammar: Self.postgreSQL))
    }

    @Test("Does not mistake identifiers containing limit for a LIMIT clause")
    func identifiersContainingLimit() {
        #expect(!hasLimit("SELECT limit_used FROM quotas"))
        #expect(!hasLimit("SELECT `limit` FROM quotas", grammar: Self.mySQL))
    }

    @Test("Detects a LIMIT before a trailing semicolon")
    func trailingSemicolon() {
        #expect(hasLimit("SELECT * FROM t LIMIT 5;"))
        #expect(!hasLimit("SELECT * FROM t;"))
    }

    // MARK: - First row-limiting clause

    @Test("firstRowLimitClauseOffset points at the top-level LIMIT, OFFSET or FETCH")
    func clauseOffsetFindsTopLevelClause() throws {
        let sql = "SELECT * FROM orders LIMIT 100"
        let offset = try #require(clauseOffset(sql))
        #expect(offset == 21)
        #expect((sql as NSString).substring(from: offset) == "LIMIT 100")
    }

    @Test("firstRowLimitClauseOffset finds a bare OFFSET with no LIMIT")
    func clauseOffsetFindsBareOffset() {
        #expect(clauseOffset("SELECT * FROM orders OFFSET 20") == 21)
    }

    @Test("firstRowLimitClauseOffset finds an ANSI FETCH clause")
    func clauseOffsetFindsFetch() {
        #expect(clauseOffset("SELECT * FROM orders OFFSET 5 ROWS FETCH NEXT 10 ROWS ONLY") == 21)
    }

    @Test("firstRowLimitClauseOffset ignores a LIMIT inside a subquery or a string")
    func clauseOffsetIgnoresNested() {
        #expect(clauseOffset("SELECT * FROM (SELECT * FROM t LIMIT 5) s") == nil)
        #expect(clauseOffset("SELECT * FROM t WHERE note = 'no LIMIT here'") == nil)
    }

    @Test("firstRowLimitClauseOffset ignores TOP, which is not a trailing clause")
    func clauseOffsetIgnoresTop() {
        #expect(clauseOffset("SELECT TOP 10 * FROM t", grammar: Self.standard) == nil)
    }

    @Test("firstRowLimitClauseOffset ignores OFFSET and FETCH used as column names")
    func clauseOffsetIgnoresIdentifiers() {
        #expect(clauseOffset("SELECT offset, name FROM events", grammar: Self.mySQL) == nil)
        #expect(clauseOffset("SELECT fetch FROM t", grammar: Self.mySQL) == nil)
        #expect(clauseOffset("SELECT offset FROM t ORDER BY offset", grammar: Self.mySQL) == nil)
    }

    @Test("firstRowLimitClauseOffset accepts a placeholder row count")
    func clauseOffsetAcceptsPlaceholders() {
        #expect(clauseOffset("SELECT * FROM t LIMIT ?", grammar: Self.mySQL) != nil)
        #expect(clauseOffset("SELECT * FROM t LIMIT $1") != nil)
        #expect(clauseOffset("SELECT * FROM t LIMIT ALL") != nil)
    }

    // MARK: - Appending a limit

    @Test("The appended clause goes on a line of its own, after the trailing semicolons and blanks", arguments: [
        ("SELECT * FROM t", "SELECT * FROM t\nLIMIT 11"),
        ("SELECT * FROM t;", "SELECT * FROM t\nLIMIT 11"),
        ("  SELECT * FROM t ; ;\n\t", "SELECT * FROM t\nLIMIT 11"),
        ("SELECT * FROM t -- newest first", "SELECT * FROM t -- newest first\nLIMIT 11"),
    ])
    func appendingLimit(sql: String, expected: String) {
        #expect(SQLStatementRowLimit.appendingLimit(11, to: sql) == expected)
    }

    @Test("A LIMIT appended after a trailing line comment is still read as code")
    func appendedLimitSurvivesLineComment() {
        let bounded = SQLStatementRowLimit.appendingLimit(11, to: "SELECT * FROM t -- newest first")
        #expect(SQLStatementRowLimit.hasExplicitRowLimit(bounded, countsTop: false, grammar: Self.sqlite))
    }

    @Test("FETCH FIRST is appended the same way", arguments: [
        ("SELECT * FROM t;\n", "SELECT * FROM t\nFETCH FIRST 11 ROWS ONLY"),
        ("SELECT * FROM t -- newest first", "SELECT * FROM t -- newest first\nFETCH FIRST 11 ROWS ONLY"),
    ])
    func appendingFetchFirst(sql: String, expected: String) {
        #expect(SQLStatementRowLimit.appendingFetchFirst(11, to: sql) == expected)
    }

    // MARK: - Leading keyword

    @Test("The leading keyword is the first word, uppercased, past blanks and comments", arguments: [
        ("SELECT 1", "SELECT"),
        ("select * from t", "SELECT"),
        ("  \n\tWith c AS (SELECT 1) SELECT * FROM c", "WITH"),
        ("-- latest orders\nSELECT * FROM orders", "SELECT"),
        ("/* one */ /* two */\n-- three\nwith c AS (SELECT 1) SELECT * FROM c", "WITH"),
        ("VALUES (1), (2)", "VALUES"),
        ("(SELECT 1) UNION (SELECT 2)", "SELECT"),
        ("pragma table_info(t)", "PRAGMA"),
    ])
    func leadingKeyword(sql: String, expected: String) {
        #expect(SQLStatementRowLimit.leadingKeyword(sql, grammar: Self.sqlite) == expected)
    }

    @Test("A statement that is only blanks and comments has no leading keyword", arguments: [
        "", "  \n", "-- nothing here", "/* only a comment */",
    ])
    func noLeadingKeyword(sql: String) {
        #expect(SQLStatementRowLimit.leadingKeyword(sql, grammar: Self.sqlite) == nil)
    }

    @Test("A comment marker the grammar does not read as one is not skipped")
    func leadingKeywordFollowsTheGrammar() {
        #expect(SQLStatementRowLimit.leadingKeyword("# note\nSELECT 1", grammar: Self.mySQL) == "SELECT")
        #expect(SQLStatementRowLimit.leadingKeyword("# note\nSELECT 1", grammar: Self.sqlite) == nil)
    }
}
