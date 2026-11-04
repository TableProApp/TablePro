import Foundation
import TableProSQLGrammar
import Testing

struct DatabendTokenizerTests {
    private static func spellings(_ sql: String, _ rules: DatabendTokenizer.Rules = .current) -> [String] {
        let scalars = Array(sql.unicodeScalars)
        return DatabendTokenizer.read(scalars, rules: rules).tokens.map {
            String(String.UnicodeScalarView(scalars[$0.range]))
        }
    }

    private static func kinds(_ sql: String) -> [DatabendTokenizer.Kind] {
        DatabendTokenizer.read(Array(sql.unicodeScalars)).tokens.map(\.kind)
    }

    private static var pairedStars: DatabendTokenizer.Rules {
        var rules = DatabendTokenizer.Rules.current
        rules.pairsStarsInBlockComments = true
        return rules
    }

    // Measured on 1.2.880 and 1.2.958: each text dropped the table.
    @Test("A hint skipped at the start is read as tokens through the first `*/` outside them", arguments: [
        "/*+ ' */ SELECT 1 -- ' */ DROP TABLE t",
        "/*+ @x*/ SELECT 1 */ DROP TABLE t",
        "/*+ $$ */ SELECT $$ */ DROP TABLE t",
        "/*+ /*+ */ SELECT 1 */ DROP TABLE t",
        "/*+ SET_VAR(max_threads=1) */ DROP TABLE t",
    ])
    func skippedHintIsTokens(sql: String) {
        #expect(Self.spellings(sql) == ["DROP", "TABLE", "t"])
    }

    @Test("A hint after a word that takes one stays for the parser, and one after MERGE only on a newer release")
    func takenHintStays() {
        #expect(Self.kinds("SELECT /*+ SET_VAR(a=1) */ 1") == [
            .name, .hintPrefix, .name, .symbol, .name, .symbol, .number, .symbol, .hintSuffix, .number,
        ])
        #expect(Self.spellings("MERGE /*+ x */ INTO t") == ["MERGE", "/*+", "x", "*/", "INTO", "t"])
        var older = DatabendTokenizer.Rules.current
        older.mergeTakesHints = false
        #expect(Self.spellings("MERGE /*+ x */ INTO t", older) == ["MERGE", "INTO", "t"])
    }

    // Measured on 1.2.880, which dropped the table, and 1.2.958, which refused the text.
    @Test("A release before 1.2.884 pairs a block comment's stars, so `**/` and `/**/` leave it open")
    func pairedStarsLeaveACommentOpen() {
        let sql = "/** x **/ SELECT 1 /* */ DROP TABLE t"
        #expect(Self.spellings(sql) == ["SELECT", "1", "DROP", "TABLE", "t"])
        #expect(Self.spellings(sql, Self.pairedStars) == ["DROP", "TABLE", "t"])
        #expect(Self.spellings("/**/ SELECT 1 /* */ DROP TABLE t", Self.pairedStars) == ["DROP", "TABLE", "t"])
        #expect(Self.spellings("/***/ SELECT 1", Self.pairedStars) == ["SELECT", "1"])
        #expect(DatabendTokenizer.Rules.readings(of: Array(sql.unicodeScalars)).contains(Self.pairedStars))
    }

    // Measured on 1.2.880 and 1.2.958: each text was refused at the token that does not end.
    @Test("The reading stops where the server refuses the rest", arguments: [
        "SELECT 1 /* x", "SELECT 1 $$x", "SELECT 1 'x", "SELECT 1 `x", "SELECT 1 'a\\\nb'",
    ])
    func stopsWhereTheServerStops(sql: String) {
        let reading = DatabendTokenizer.read(Array(sql.unicodeScalars))
        #expect(!reading.isComplete)
        #expect(reading.tokens.count == 2)
    }

    @Test("A stage name keeps a quote or a space after a backslash, and `*/` and `/*` with no space")
    func stageNamesKeepEscapedQuotes() {
        #expect(Self.spellings("COPY INTO t FROM @s\\' x") == ["COPY", "INTO", "t", "FROM", "@s\\'", "x"])
        #expect(Self.spellings("SELECT * FROM @s/*/ x") == ["SELECT", "*", "FROM", "@s/*/", "x"])
        #expect(Self.kinds("SELECT a @> b, c @? d") == [.name, .name, .symbol, .name, .symbol, .name, .symbol, .name])
    }

    // Measured on 1.2.880 and 1.2.958: `a$$` is one name, and `$$` after a number opens a code string.
    @Test("A `$$` continues a name and opens a code string after anything else")
    func dollarQuotesFollowTokens() {
        #expect(Self.spellings("SELECT 1 AS a$$, 2") == ["SELECT", "1", "AS", "a$$", ",", "2"])
        #expect(Self.spellings("SELECT 1e5$$ x $$") == ["SELECT", "1e5", "$$ x $$"])
        #expect(Self.kinds("SELECT $1, $a, $") == [.name, .variable, .symbol, .variable, .symbol, .symbol])
    }

    @Test("A doubled backtick stays inside a name")
    func doubledBacktickStaysInAName() {
        #expect(Self.spellings("SELECT `a``b`, ?") == ["SELECT", "`a``b`", ",", "?"])
    }

    @Test("A form feed ends a line comment and a carriage return does not")
    func lineCommentEnds() {
        #expect(Self.spellings("SELECT 1 --x\u{0C}, 2") == ["SELECT", "1", ",", "2"])
        #expect(Self.spellings("SELECT 1 --x\r, 2") == ["SELECT", "1"])
    }

    @Test("An operator is read whole, so `*/*` and `//*` open no comment and `#--` none either")
    func operatorsStayWhole() {
        #expect(Self.spellings("SELECT 2 */* ' */ 3 '") == ["SELECT", "2", "*/", "*", "' */ 3 '"])
        #expect(Self.spellings("SELECT 4 //* 2") == ["SELECT", "4", "//", "*", "2"])
        #expect(Self.spellings("SELECT 1 #-- 2") == ["SELECT", "1", "#-", "-", "2"])
        #expect(Self.kinds("SELECT j ?| x, ?") == [.name, .name, .symbol, .name, .symbol, .placeholder])
    }

    @Test("Placeholders are the `?` tokens the parser reads, a hint the server skips holding none")
    func placeholders() {
        let sql = Array("/*+ ? */ SELECT ?, '?', /*+ ? */ ? -- ?".unicodeScalars)
        #expect(DatabendTokenizer.placeholders(in: sql) == [16, 33])
    }
}
