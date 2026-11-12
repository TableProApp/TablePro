import Foundation
import TableProSQLGrammar
import Testing

@Suite("SQL non-code spans")
struct SQLNonCodeSpanTests {
    private func end(_ text: String, at index: Int = 0, _ grammar: SQLLexicalGrammar) -> Int? {
        SQLNonCodeSpan.span(at: index, in: text as NSString, grammar: grammar)?.end
    }

    @Test("A backslash keeps a quote open only where the grammar says so")
    func backslashFollowsTheGrammar() {
        #expect(end("'a\\' b'", .ansi) == 4)
        #expect(end("'a\\' b'", .backslashEscapesInSingleQuotes) == 7)
        #expect(end("\"a\\\" b\"", .backslashEscapesInSingleQuotes) == 4)
        #expect(end("`a\\` b`", [.backtickQuotes, .backslashEscapesInSingleQuotes]) == 4)
        #expect(end("`a\\` b`", [.backtickQuotes, .backslashEscapesInBackticks]) == 7)
    }

    @Test("A backtick quotes only where the grammar reads it")
    func backtickFollowsTheGrammar() {
        #expect(end("`a;b`", .ansi) == nil)
        #expect(end("`a;b`", .backtickQuotes) == 5)
    }

    @Test("Block comments nest only where the grammar says so")
    func nestingFollowsTheGrammar() {
        let text = "/* a /* b */ c */ d"
        #expect(end(text, .ansi) == 12)
        #expect(end(text, .nestedBlockComments) == 17)
    }

    @Test("Brackets quote an identifier only where the grammar says so, and ]] escapes only on T-SQL")
    func bracketsFollowTheGrammar() {
        #expect(end("[a]]b] c", .ansi) == nil)
        #expect(end("[a]]b] c", .bracketQuotedIdentifiers) == 3)
        #expect(end("[a]]b] c", [.bracketQuotedIdentifiers, .doubledClosingBracketEscapes]) == 6)
    }

    @Test("SurrealQL's ⟨...⟩ quotes an identifier only where the grammar says so, and ⟩⟩ escapes nothing")
    func angleQuotesFollowTheGrammar() {
        #expect(end("⟨it's⟩ x", .ansi) == nil)
        #expect(end("⟨it's⟩ x", .angleQuotedIdentifiers) == 6)
        #expect(end("⟨a⟩⟩b⟩ x", .angleQuotedIdentifiers) == 3)
        #expect(end("⟨a\\⟩b⟩ x", .angleQuotedIdentifiers) == 4)
        #expect(end("⟨a\\⟩b⟩ x", [.angleQuotedIdentifiers, .backslashEscapesInBackticks]) == 4)
        #expect(end("⟨a\\⟩b⟩ x", [.angleQuotedIdentifiers, .backslashEscapesInAngleQuotes]) == 6)
        #expect(end("⟨a b", .angleQuotedIdentifiers) == 4)
    }

    @Test("Line comments start with #, // and -- as the grammar reads them")
    func lineCommentsFollowTheGrammar() {
        #expect(end("# a\nb", .ansi) == nil)
        #expect(end("# a\nb", .hashLineComments) == 3)
        #expect(end("// a\nb", .ansi) == nil)
        #expect(end("// a\nb", .doubleSlashLineComments) == 4)
        #expect(end("--a\nb", .ansi) == 3)
        #expect(end("--a\nb", .dashCommentsNeedWhitespace) == nil)
        #expect(end("-- a\nb", .dashCommentsNeedWhitespace) == 4)
        #expect(end("--", .dashCommentsNeedWhitespace) == 2)
    }

    @Test("Cypher's -- is code under every reading of a Neo4j text, so the ; after it still splits")
    func cypherDashesAreCode() {
        #expect(end("-- a\nb", .withoutDashComments) == nil)
        let text = "MATCH (a)-- (b) RETURN a; MATCH (n) RETURN n"
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "Neo4j", declared: nil, session: nil)
        for grammar in readings.distinct(for: text) {
            #expect(SQLStatementScanner.executableStatements(in: text, grammar: grammar).count == 2)
        }
    }

    @Test("Every control character after -- starts a MySQL comment, U+007F among them")
    func deleteAfterDashesStartsAComment() {
        #expect(end("--\u{01}a\nb", .dashCommentsNeedWhitespace) == 4)
        #expect(end("--\u{7F}a\nb", .dashCommentsNeedWhitespace) == 4)
        let hidden = "WITH c AS (SELECT 1 --\u{7F}'\n) DELETE FROM orders -- '"
        for engine in ["MySQL", "MariaDB"] {
            let readings = SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil)
            #expect(readings.all.allSatisfy {
                SQLCodeProjection.code(of: hidden, grammar: $0).contains("DELETE FROM orders")
            })
        }
    }

    @Test("The - after a number's e opens no comment where an exponent takes its sign without digits")
    func exponentSignFollowsTheGrammar() {
        #expect(end("1E--a\nb", at: 2, .ansi) == 5)
        #expect(end("1E--a\nb", at: 2, .exponentSignsNeedNoDigits) == nil)
        #expect(end("1E---a\nb", at: 3, .exponentSignsNeedNoDigits) == 6)
        #expect(end("xE--a\nb", at: 2, .exponentSignsNeedNoDigits) == 5)
        #expect(SQLCodeProjection.code(of: "1E--1 a -- b", grammar: .exponentSignsNeedNoDigits) == "1E--1 a     ")
    }

    @Test("A form feed ends a line comment only where the engine ends it there")
    func formFeedFollowsTheGrammar() {
        #expect(end("-- a\u{0C}b\nc", .ansi) == 6)
        #expect(end("-- a\u{0C}b\nc", .formFeedEndsLineComments) == 4)
    }

    @Test("A lone carriage return ends a line comment only where the engine ends it there")
    func carriageReturnFollowsTheGrammar() {
        #expect(end("-- a\rb\nc", .ansi) == 6)
        #expect(end("-- a\rb\nc", .carriageReturnEndsLineComments) == 4)
    }

    @Test("E'...' escapes with a backslash, and only where a word could start")
    func escapeStringPrefix() {
        #expect(end("E'\\'' x", .escapeStringPrefix) == 5)
        #expect(end("xE'\\'' x", at: 1, .escapeStringPrefix) == nil)
        #expect(end("E'\\'' x", .ansi) == nil)
    }

    private static func execution(_ engine: String) -> SQLLexicalGrammar {
        SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil).execution
    }

    private static func statements(_ sql: String, _ engine: String) -> Int {
        SQLStatementScanner.executableStatements(in: sql, grammar: execution(engine)).count
    }

    private static func tier(_ sql: String, _ engine: String) -> StatementTier {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil)
        return SQLStatementClassifier.classify(sql, databaseTypeId: engine, readings: readings).tier
    }

    // Measured on PostgreSQL 17.11: with a domain named after each glued name, the server ran the DROP.
    @Test(
        "A prefix glued to a name by $ or by any non-ASCII unit is part of the name on PostgreSQL",
        arguments: ["$", "\u{E9}", "\u{00A0}", "\u{3000}", "\u{200B}", "\u{2060}", "\u{FEFF}", "\u{2019}", "\u{FF0C}"]
    )
    func prefixAfterANameOnPostgreSQL(glue: String) {
        let sql = "SELECT x\(glue)e'\\'; DROP TABLE t; --'"
        for engine in ["PostgreSQL", "CockroachDB", "Redshift"] {
            #expect(Self.statements(sql, engine) == 2, "\(engine)")
            #expect(Self.tier(sql, engine) == .destructive, "\(engine)")
        }
        #expect(Self.statements("SELECT x\(glue)b'\\'; DROP TABLE t; --'", "CockroachDB") == 2)
    }

    // Measured on DuckDB 1.5.4 and 2.0.0: these spaces end `varchar` and the DROP ran; every other unit kept it a name.
    @Test("DuckDB ends a name at the non-ASCII spaces it blanks before lexing and at no other non-ASCII unit")
    func prefixAfterANameOnDuckDB() {
        let blanks: [UInt16] = [0x00A0, 0x2000, 0x2005, 0x200A, 0x200B, 0x202F, 0x205F, 0x2060, 0x3000, 0xFEFF]
        for unit in blanks {
            let space = String(utf16CodeUnits: [unit], count: 1)
            let sql = "SELECT varchar\(space)E'\\''; DROP TABLE t; --'"
            #expect(Self.statements(sql, "DuckDB") == 2, "U+\(String(unit, radix: 16))")
            #expect(Self.tier(sql, "DuckDB") == .destructive, "U+\(String(unit, radix: 16))")
            #expect(Self.statements(sql, "PostgreSQL") == 1, "U+\(String(unit, radix: 16))")
        }
        for glue in ["$", "\u{E9}", "\u{200C}", "\u{2019}", "\u{FF0C}", "\u{2028}"] {
            #expect(Self.statements("SELECT x\(glue)e'\\'; DROP TABLE t; --'", "DuckDB") == 2, "\(glue)")
            #expect(Self.statements("SELECT varchar\(glue)E'\\''; DROP TABLE t; --'", "DuckDB") == 1, "\(glue)")
        }
    }

    // Measured on DuckDB 2.0.0: after these spaces `$$` opened a dollar quote and the DROP ran.
    @Test("DuckDB opens a dollar quote after a space it blanks, and PostgreSQL keeps the $ in the name")
    func dollarQuoteAfterABlankOnDuckDB() {
        for space in ["\u{00A0}", "\u{200B}", "\u{3000}"] {
            let sql = "SELECT 1 AS a,\(space)$$'$$; DROP TABLE t; SELECT 'x'"
            #expect(Self.statements(sql, "DuckDB") == 3)
            #expect(Self.tier(sql, "DuckDB") == .destructive)
            #expect(Self.statements(sql, "PostgreSQL") == 1)
        }
        #expect(Self.statements("SELECT 1 AS a,\u{2019}$$'$$; DROP TABLE t; SELECT 'x'", "DuckDB") == 1)
    }

    // Measured on DuckDB 1.5.4 and 2.0.0: its pre-lexing pass kept the space in each text, so the `$$` stayed in the
    // name and the DROP ran.
    @Test("A gate reads DuckDB both ways, since it keeps a non-ASCII space where its pre-lexing pass sees a quote", arguments: [
        "SELECT 1 AS a$$, 2 AS b\u{200B}$$; DROP TABLE t; --$$",
        "/* ' */ SELECT 1 AS a\u{200B}$$; DROP TABLE t; --$$",
        "SELECT E'\\'' AS c, 1 AS a\u{200B}$$; DROP TABLE t; --$$",
    ])
    func duckDBKeepsSomeSpaces(sql: String) {
        #expect(Self.tier(sql, "DuckDB") == .destructive)
    }

    @Test("A q'...' glued to a name by $ or # is part of the name where both continue one")
    func alternativeQuoteAfterAName() {
        for engine in ["Oracle", "Dameng"] {
            #expect(end("x$q'[it's]'", at: 2, Self.execution(engine)) == nil, "\(engine)")
            #expect(end("x#q'[it's]'", at: 2, Self.execution(engine)) == nil, "\(engine)")
            #expect(Self.statements("SELECT x$q'['; DROP TABLE t; --]' FROM dual", engine) == 2, "\(engine)")
        }
        #expect(end("x#e'\\'' y", at: 2, Self.execution("PostgreSQL")) == 7)
    }

    @Test("A string after a line break continues a PostgreSQL E'...' with its escapes, as quotecontinue reads it")
    func escapeStringContinuesAfterALineBreak() {
        let postgreSQL = Self.execution("PostgreSQL")
        #expect(end("E'x'\n'\\' || 'y", postgreSQL) == 13)
        #expect(end("E'x'\r'y' z", postgreSQL) == 8)
        #expect(end("E'x'\u{0B}\n'y' z", postgreSQL) == 9)
        #expect(end("E'x'\n\u{0B}\u{0C}\t 'y' z", postgreSQL) == 12)
        #expect(end("E'x' -- c\n'y' z", postgreSQL) == 13)
        #expect(end("E'x'\n-- c\n'y' z", postgreSQL) == 13)
        #expect(end("E'x'\n'y'\n\n'z' w", postgreSQL) == 13)
        #expect(end("E'x'\u{00A0}\n\u{3000}'y' z", postgreSQL) == 10)
        #expect(end("E'x'\u{200C}\n'y' z", postgreSQL) == 4)
        #expect(SQLNonCodeSpan.span(at: 0, in: "E'x'\r\n'y'\n'z'" as NSString, grammar: postgreSQL)?.newlines == 2)
    }

    @Test("An E'...' ends at its quote without a line break, across a block comment, or on DuckDB")
    func escapeStringEndsAtItsQuote() {
        let postgreSQL = Self.execution("PostgreSQL")
        #expect(end("E'x' 'y'", postgreSQL) == 4)
        #expect(end("E'x' /* c */\n'y'", postgreSQL) == 4)
        #expect(end("E'x' -- c'y'", postgreSQL) == 4)
        #expect(end("E'x'\n-- c'y'", postgreSQL) == 4)
        #expect(end("E'x'\nz 'y'", postgreSQL) == 4)
        #expect(end("'x'\n'\\' || 'y", postgreSQL) == 3)
        #expect(end("E'x'\n'\\' || 'y", Self.execution("DuckDB")) == 4)
    }

    @Test("b'...' escapes with a backslash where it is a byte literal, and B'...' never does")
    func escapeBytesPrefix() {
        #expect(end("b'\\'' x", .escapeBytesPrefix) == 5)
        #expect(end("xb'\\'' x", at: 1, .escapeBytesPrefix) == nil)
        #expect(end("B'\\'' x", .escapeBytesPrefix) == nil)
        #expect(end("b'\\'' x", .escapeStringPrefix) == nil)
    }

    @Test("q'[...]' runs to its closing delimiter, and only where a word could start")
    func alternativeQuoting() {
        #expect(end("q'[it's]' x", .alternativeQuoting) == 9)
        #expect(end("nq'{a'b}' x", .alternativeQuoting) == 9)
        #expect(end("xq'[it's]'", at: 1, .alternativeQuoting) == nil)
    }

    @Test("Tagged dollar quotes take non-ASCII tags, untagged ones take only $$")
    func dollarQuoteStyles() {
        #expect(end("$ü$a;b$ü$ c", .taggedDollarQuotes) == 9)
        #expect(end("$tag$a;b$tag$ c", .taggedDollarQuotes) == 13)
        #expect(end("$tag$a;b$tag$ c", .untaggedDollarQuotes) == nil)
        #expect(end("$$a;b$$ c", .untaggedDollarQuotes) == 7)
        #expect(end("$1", .taggedDollarQuotes) == nil)
    }

    @Test("A dollar glued to an identifier, ASCII or not, never opens a body")
    func gluedDollarIsIdentifier() {
        #expect(end("x$$;$$", at: 1, .taggedDollarQuotes) == nil)
        #expect(end("é$$;$$", at: 1, .taggedDollarQuotes) == nil)
        #expect(end(" $$;$$", at: 1, .taggedDollarQuotes) == 6)
    }

    @Test("A dollar quote closes on the same code units, not on a canonically equivalent tag")
    func dollarTagsMatchByCodeUnit() {
        #expect(end("$K$ $\u{212A}$ $K$ x", .taggedDollarQuotes) == 11)
        #expect(end("$\u{C5}$ $\u{212B}$ $\u{C5}$ x", .taggedDollarQuotes) == 11)
        #expect(end("$a\u{301}\u{323}$ $a\u{323}\u{301}$ $a\u{301}\u{323}$ x", .taggedDollarQuotes) == 17)
    }

    @Test("A triple-quoted literal holds a lone quote")
    func tripleQuotes() {
        #expect(end("'''it's''' x", .tripleQuotedStrings) == 10)
        #expect(end("'''it's''' x", .ansi) == 6)
    }

    @Test("An alternative quote whose delimiter is outside the BMP closes at that delimiter and a quote")
    func alternativeQuoteTakesAnAstralDelimiter() {
        #expect(end("q'\u{4E2D}a;b\u{4E2D}' c", .alternativeQuoting) == 8)
        #expect(end("q'\u{1F600}a;b\u{1F600}' c", .alternativeQuoting) == 10)
        #expect(end("nq'\u{1F600}a\u{1F601}';\u{1F600}' c", .alternativeQuoting) == 13)
        #expect(SQLNonCodeSpan.span(at: 0, in: "q'\u{1F600}a;b\u{1F600}' c", grammar: .alternativeQuoting)?.contentEnd == 7)
        let hidden = "SELECT q'\u{1F600}x\u{1F600}' FROM dual; DROP TABLE users"
        #expect(SQLStatementScanner.allStatements(in: hidden, grammar: .alternativeQuoting).count == 2)
    }

    @Test("SQLite's $name(...) parameter runs to its ) or to whitespace")
    func parenthesizedParameters() {
        #expect(end("$a('); x", .parenthesizedParameterNames) == 5)
        #expect(end("@a::b(;) x", .parenthesizedParameterNames) == 8)
        #expect(end("$ab(x y)", .parenthesizedParameterNames) == 5)
        #expect(end("$(x)", .parenthesizedParameterNames) == nil)
        #expect(end("$a('); x", .ansi) == nil)
    }

    @Test("A control character SQLite does not read as whitespace stays inside its $name(...) parameter")
    func controlCharacterStaysInsideAParameter() {
        for control: UInt8 in Array(0x01...0x08) + Array(0x0E...0x1F) + [0x7F] {
            #expect(end("$a(\(Character(UnicodeScalar(control)))') x", .parenthesizedParameterNames) == 6)
        }
        for blank in ["\0", "\t", "\n", "\u{0B}", "\u{0C}", "\r", " "] {
            #expect(end("$a(\(blank)') x", .parenthesizedParameterNames) == 3)
        }
        let hidden = "WITH c AS (SELECT $a(\u{01}')) DELETE FROM orders --'"
        let sqlite = SQLLexicalReadings.resolve(databaseTypeId: "SQLite", declared: nil, session: nil)
        #expect(sqlite.all.allSatisfy { SQLCodeProjection.code(of: hidden, grammar: $0).contains("DELETE FROM") })
    }

    @Test("A $ inside a SQLite name starts no parameter, measured on 3.46")
    func dollarInsideANameStartsNoParameter() {
        #expect(end("x$y(')') z", at: 1, .parenthesizedParameterNames) == nil)
        #expect(end("\u{E9}$y(')') z", at: 1, .parenthesizedParameterNames) == nil)
        #expect(end("x\u{FEFF}$y(')') z", at: 2, .parenthesizedParameterNames) == nil)
        #expect(end("x1$y(')') z", at: 2, .parenthesizedParameterNames) == nil)
        #expect(end("x@y(')') z", at: 1, .parenthesizedParameterNames) == 6)
        #expect(end(" $y(')') z", at: 1, .parenthesizedParameterNames) == 6)
        #expect(end("\u{FEFF}$y(')') z", at: 1, .parenthesizedParameterNames) == 6)
        #expect(end("?1$y(')') z", at: 2, .parenthesizedParameterNames) == 7)
        let hidden = "WITH x$y(\"')\") AS (SELECT 1) DELETE FROM users --\""
        #expect(SQLCodeProjection.code(of: hidden, grammar: .parenthesizedParameterNames).contains("DELETE"))
    }

    @Test("A MySQL executable comment reads its body as SQL, so a quoted */ does not close it")
    func executableCommentIsQuoteAware() {
        let text = "/*!40101 , '*/' */ x"
        let span = SQLNonCodeSpan.span(at: 0, in: text as NSString, grammar: [.executableComments])
        #expect(span?.kind == .executableComment)
        #expect(span?.end == 18)
        #expect(SQLNonCodeSpan.end(at: 0, in: text as NSString, grammar: [.executableComments]) == nil)
        #expect(end(text, .ansi) == 14)
    }

    @Test(
        "A run executable comment lexes its body as code, comments included",
        arguments: [
            ("/*! /* ' */ DROP TABLE t */ x", 27),
            ("/*! DROP TABLE t # */ '\n */ x", 27),
            ("/*! DROP TABLE t -- */ '\n */ x", 28),
            ("/*! DROP TABLE /*! t */ x", 23),
            ("/*!40101 SET @a = '*/' */ x", 25),
        ]
    )
    func executableCommentBodyIsCode(text: String, end: Int) {
        let grammar: SQLLexicalGrammar = [.executableComments, .hashLineComments, .dashCommentsNeedWhitespace]
        let span = SQLNonCodeSpan.span(at: 0, in: text as NSString, grammar: grammar)
        #expect(span?.kind == .executableComment)
        #expect(span?.end == end)
        #expect(span?.isTerminated == true)
    }

    @Test("A lowercase /*m! is a plain comment, as MySQL and MariaDB read it")
    func lowercaseMarkerIsAPlainComment() {
        let text = "/*m! ' */ DROP TABLE t -- '" as NSString
        let span = SQLNonCodeSpan.span(at: 0, in: text, grammar: [.executableComments])
        #expect(span?.kind == .blockComment)
        #expect(span?.end == 9)
    }

    @Test("A span the text ends inside is reported unterminated")
    func unterminatedSpans() {
        let grammar: SQLLexicalGrammar = [.taggedDollarQuotes, .bracketQuotedIdentifiers]
        for text in ["'abc", "/* abc", "$$abc", "[abc", "'abc\\'"] {
            let span = SQLNonCodeSpan.span(at: 0, in: text as NSString, grammar: grammar.union(.backslashEscapesInSingleQuotes))
            #expect(span?.isTerminated == false, "\(text)")
        }
        #expect(SQLNonCodeSpan.span(at: 0, in: "'abc'" as NSString, grammar: .ansi)?.isTerminated == true)
    }

    @Test("The code projection keeps every offset and blanks every literal and comment")
    func codeProjectionKeepsOffsets() {
        let text = "SELECT 'a;b', \"c\" /* d */ FROM t -- e\nWHERE x = $$f$$"
        let code = SQLCodeProjection.code(of: text, grammar: .taggedDollarQuotes)
        #expect((code as NSString).length == (text as NSString).length)
        #expect(!code.contains("a;b"))
        #expect(!code.contains(" d "))
        #expect(code.contains("FROM t"))
        #expect(code.contains("WHERE x ="))
        #expect(!code.contains("f"))
    }

    @Test("Revealing an executable comment keeps its body as code only where the grammar runs one")
    func codeProjectionRevealsExecutableComments() {
        let text = "SELECT 1 /*!40101 DROP TABLE t */"
        #expect(!SQLCodeProjection.code(of: text, grammar: .ansi).contains("DROP"))
        #expect(!SQLCodeProjection.code(of: text, grammar: .ansi, revealingExecutableComments: true).contains("DROP"))
        #expect(
            SQLCodeProjection.code(of: text, grammar: .executableComments, revealingExecutableComments: true)
                .contains("DROP")
        )
        let sqlite = SQLCodeProjection.code(
            of: "SELECT eval/*!*/('x')", grammar: [.parenthesizedParameterNames], revealingExecutableComments: true
        )
        #expect(sqlite == "SELECT eval     (   )")
    }
}
