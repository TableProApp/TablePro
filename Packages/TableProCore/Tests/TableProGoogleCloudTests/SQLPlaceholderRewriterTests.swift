import Foundation
import TableProGoogleCloud
import Testing

@Suite("SQLPlaceholderRewriter")
struct SQLPlaceholderRewriterTests {
    private func google(_ sql: String, expected: Int? = nil) throws -> (sql: String, count: Int) {
        try SQLPlaceholderRewriter.rewrite(sql, lexicon: .googleSQL, expectedCount: expected) { "@p\($0)" }
    }

    private func postgres(_ sql: String, expected: Int? = nil) throws -> (sql: String, count: Int) {
        try SQLPlaceholderRewriter.rewrite(sql, lexicon: .postgreSQL, expectedCount: expected) { "$\($0)" }
    }

    @Test("Bare placeholders are numbered from one")
    func numbersPlaceholders() throws {
        let result = try google("UPDATE t SET a = ?, b = ? WHERE id = ?")
        #expect(result.sql == "UPDATE t SET a = @p1, b = @p2 WHERE id = @p3")
        #expect(result.count == 3)
        #expect(try postgres("SELECT ?,?").sql == "SELECT $1,$2")
    }

    @Test("No placeholder leaves the text unchanged")
    func noPlaceholders() throws {
        let (sql, placeholders) = try google("SELECT 1")
        #expect(sql == "SELECT 1")
        #expect(placeholders == 0)
    }

    @Test("GoogleSQL strings in every quoting form hide their question marks")
    func googleStrings() throws {
        let sql = #"SELECT '?', "?", 'it\'s ?', "a\"?", '''multi ' ? line''', """x "" ? """, r'?\d', b"?", rb'?', BR'''?''', ?"#
        let result = try google(sql)
        #expect(result.count == 1)
        #expect(result.sql.hasSuffix(", @p1"))
        #expect(result.sql.hasPrefix(#"SELECT '?', "?", 'it\'s ?'"#))
    }

    @Test("A raw string ending in an escaped quote does not end early")
    func rawStringBackslashQuote() throws {
        let result = try google(#"SELECT r'\'?', ?"#)
        #expect(result.sql == #"SELECT r'\'?', @p1"#)
    }

    @Test("GoogleSQL backtick identifiers and comments hide their question marks")
    func googleIdentifiersAndComments() throws {
        let sql = "SELECT `col?`, `a\\`?` -- what?\n, # hash?\n /* block ? */ ? FROM t"
        let result = try google(sql)
        #expect(result.count == 1)
        #expect(result.sql == "SELECT `col?`, `a\\`?` -- what?\n, # hash?\n /* block ? */ @p1 FROM t")
    }

    @Test("GoogleSQL block comments do not nest")
    func googleBlockCommentsDoNotNest() throws {
        let result = try google("SELECT /* a /* b */ ? */ 1")
        #expect(result.count == 1)
        #expect(result.sql == "SELECT /* a /* b */ @p1 */ 1")
    }

    @Test("A quote inside a comment does not open a string")
    func quoteInComment() throws {
        let result = try google("SELECT ? -- don't\n, ?")
        #expect(result.sql == "SELECT @p1 -- don't\n, @p2")
    }

    @Test("PostgreSQL doubled quotes and literal backslashes")
    func postgresStrings() throws {
        let result = try postgres(#"SELECT 'it''s ?', 'C:\', ?"#)
        #expect(result.sql == #"SELECT 'it''s ?', 'C:\', $1"#)
    }

    @Test("PostgreSQL escape strings honour backslash escapes")
    func postgresEscapeStrings() throws {
        let result = try postgres(#"SELECT E'a\'?', e'b''?', ?"#)
        #expect(result.sql == #"SELECT E'a\'?', e'b''?', $1"#)
    }

    @Test("A word ending in e is not an escape-string prefix")
    func postgresWordEndingInE() throws {
        let result = try postgres(#"SELECT name, 'C:\', ?"#)
        #expect(result.sql == #"SELECT name, 'C:\', $1"#)
    }

    @Test("PostgreSQL dollar quotes hide their contents")
    func postgresDollarQuotes() throws {
        let result = try postgres("SELECT $$it's ?$$, $tag$ $$ ? $tag$, $x1$?$x1$, ?")
        #expect(result.sql == "SELECT $$it's ?$$, $tag$ $$ ? $tag$, $x1$?$x1$, $1")
    }

    @Test("Positional parameters and identifiers with a dollar are not dollar quotes")
    func postgresPositionalDollar() throws {
        let result = try postgres("SELECT a$b, $1, ? FROM t$x")
        #expect(result.sql == "SELECT a$b, $1, $1 FROM t$x")
        #expect(result.count == 1)
    }

    @Test("PostgreSQL identifiers and nested comments")
    func postgresIdentifiersAndComments() throws {
        let sql = "SELECT \"a\"\"?\" /* outer /* inner ? */ still ? */ -- line ?\n, ? # ?"
        let result = try postgres(sql)
        #expect(result.sql == "SELECT \"a\"\"?\" /* outer /* inner ? */ still ? */ -- line ?\n, $1 # $2")
        #expect(result.count == 2)
    }

    @Test("Backticks mean nothing in PostgreSQL")
    func postgresBacktick() throws {
        #expect(try postgres("SELECT `?`").sql == "SELECT `$1`")
    }

    @Test("An unterminated string swallows the rest")
    func unterminated() throws {
        #expect(try google("SELECT 'abc ?").sql == "SELECT 'abc ?")
        #expect(try postgres("SELECT $q$ ?").sql == "SELECT $q$ ?")
        #expect(try google("SELECT /* ?").sql == "SELECT /* ?")
    }

    @Test("Non-ASCII text around placeholders survives")
    func unicodeSurvives() throws {
        let result = try google("SELECT '日本?', ? AS `café🙂`")
        #expect(result.sql == "SELECT '日本?', @p1 AS `café🙂`")
    }

    @Test("A count mismatch throws")
    func countMismatch() {
        #expect(throws: SQLPlaceholderRewriteError.countMismatch(found: 1, expected: 2)) {
            try google("SELECT ?, '?'", expected: 2)
        }
        #expect(throws: SQLPlaceholderRewriteError.countMismatch(found: 2, expected: 0)) {
            try postgres("SELECT ?, ?", expected: 0)
        }
    }

    @Test("A matching count passes")
    func countMatches() throws {
        #expect(try google("SELECT ?", expected: 1).sql == "SELECT @p1")
    }
}
