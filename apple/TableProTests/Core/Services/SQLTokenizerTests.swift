//
//  SQLTokenizerTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

struct SQLTokenizerTests {
    let tokenizer = SQLTokenizer()

    // MARK: - Keywords

    @Test("Recognizes standard SQL keywords")
    func standardKeywords() {
        let tokens = tokenizer.tokenize("SELECT FROM WHERE")
        let nonWS = tokens.filter { $0.type != .whitespace }
        #expect(nonWS.count == 3)
        #expect(nonWS.allSatisfy { $0.type == .keyword })
    }

    @Test("Keywords are case-insensitive")
    func keywordCaseInsensitive() {
        let tokens = tokenizer.tokenize("select FROM Where")
        let nonWS = tokens.filter { $0.type != .whitespace }
        #expect(nonWS.allSatisfy { $0.type == .keyword })
    }

    // MARK: - Identifiers

    @Test("Recognizes identifiers")
    func identifiers() {
        let tokens = tokenizer.tokenize("users my_table col1")
        let nonWS = tokens.filter { $0.type != .whitespace }
        #expect(nonWS.count == 3)
        #expect(nonWS.allSatisfy { $0.type == .identifier })
    }

    @Test("Backtick-quoted identifiers")
    func backtickIdentifiers() {
        let tokens = tokenizer.tokenize("`my table`")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .identifier)
        #expect(tokens[0].value == "`my table`")
    }

    // MARK: - Strings

    @Test("Single-quoted string")
    func singleQuotedString() {
        let tokens = tokenizer.tokenize("'hello world'")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .string)
        #expect(tokens[0].value == "'hello world'")
    }

    @Test("String with escaped quote")
    func stringWithEscapedQuote() {
        let tokens = tokenizer.tokenize("'it''s'")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .string)
        #expect(tokens[0].value == "'it''s'")
    }

    @Test("String with backslash escape")
    func stringWithBackslashEscape() {
        let tokens = tokenizer.tokenize("'it\\'s'")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .string)
    }

    // MARK: - Unterminated literals

    @Test("Unterminated string ending in a backslash")
    func unterminatedStringEndingInBackslash() {
        let tokens = tokenizer.tokenize("'C:\\")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .string)
        #expect(tokens[0].value == "'C:\\")
    }

    @Test("Unterminated double-quoted string ending in a backslash")
    func unterminatedDoubleQuotedStringEndingInBackslash() {
        let tokens = tokenizer.tokenize("\"C:\\")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .string)
        #expect(tokens[0].value == "\"C:\\")
    }

    @Test("Unterminated backtick identifier ending in a backslash")
    func unterminatedBacktickEndingInBackslash() {
        let tokens = tokenizer.tokenize("`C:\\")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .identifier)
        #expect(tokens[0].value == "`C:\\")
    }

    @Test("Unterminated string ending in a backslash inside a statement")
    func unterminatedStringEndingInBackslashInStatement() {
        let tokens = tokenizer.tokenize("select * from t where c like 'C:\\")
        let nonWS = tokens.filter { $0.type != .whitespace }
        #expect(nonWS.last?.type == .string)
        #expect(nonWS.last?.value == "'C:\\")
    }

    @Test("Unterminated string keeps a doubled trailing backslash")
    func unterminatedStringWithDoubledBackslash() {
        let tokens = tokenizer.tokenize("'C:\\\\")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .string)
        #expect(tokens[0].value == "'C:\\\\")
    }

    @Test("Unterminated string without an escape")
    func unterminatedStringWithoutEscape() {
        let tokens = tokenizer.tokenize("'abc")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .string)
        #expect(tokens[0].value == "'abc")
    }

    @Test("Lone quote")
    func loneQuote() {
        let tokens = tokenizer.tokenize("'")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .string)
        #expect(tokens[0].value == "'")
    }

    // MARK: - Unterminated comments

    @Test("Unterminated block comment keeps its last character")
    func unterminatedBlockComment() {
        let tokens = tokenizer.tokenize("/* abc")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .comment)
        #expect(tokens[0].value == "/* abc")
    }

    @Test("Block comment opener with nothing after it")
    func emptyUnterminatedBlockComment() {
        let tokens = tokenizer.tokenize("/*")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .comment)
        #expect(tokens[0].value == "/*")
    }

    @Test("Terminated block comment is unchanged")
    func terminatedBlockComment() {
        let tokens = tokenizer.tokenize("/* abc */")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .comment)
        #expect(tokens[0].value == "/* abc */")
    }

    // MARK: - Numbers

    @Test("Integer")
    func integer() {
        let tokens = tokenizer.tokenize("42")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .number)
        #expect(tokens[0].value == "42")
    }

    @Test("Decimal number")
    func decimal() {
        let tokens = tokenizer.tokenize("3.14")
        #expect(tokens.count == 1)
        #expect(tokens[0].type == .number)
    }

    // MARK: - Comments

    @Test("Line comment")
    func lineComment() {
        let tokens = tokenizer.tokenize("-- this is a comment\nSELECT 1")
        let comments = tokens.filter { $0.type == .comment }
        #expect(comments.count == 1)
        #expect(comments[0].value == "-- this is a comment")
    }

    @Test("Block comment")
    func blockComment() {
        let tokens = tokenizer.tokenize("/* block */ SELECT 1")
        let comments = tokens.filter { $0.type == .comment }
        #expect(comments.count == 1)
        #expect(comments[0].value == "/* block */")
    }

    // MARK: - Operators

    @Test("Multi-character operators")
    func multiCharOperators() {
        let tokens = tokenizer.tokenize(">= <= <> !=")
        let ops = tokens.filter { $0.type == .operator }
        #expect(ops.count == 4)
        #expect(ops.map(\.value) == [">=", "<=", "<>", "!="])
    }

    // MARK: - Punctuation

    @Test("Punctuation tokens")
    func punctuation() {
        let tokens = tokenizer.tokenize("(a, b)")
        let puncts = tokens.filter { $0.type == .punctuation }
        #expect(puncts.map(\.value) == ["(", ",", ")"])
    }

    @Test("Semicolons")
    func semicolons() {
        let tokens = tokenizer.tokenize("SELECT 1; SELECT 2;")
        let semis = tokens.filter { $0.type == .punctuation && $0.value == ";" }
        #expect(semis.count == 2)
    }

    // MARK: - Placeholders

    @Test("Question mark placeholder")
    func questionMarkPlaceholder() {
        let tokens = tokenizer.tokenize("WHERE id = ?")
        let placeholders = tokens.filter { $0.type == .placeholder }
        #expect(placeholders.count == 1)
        #expect(placeholders[0].value == "?")
    }

    @Test("Named placeholders")
    func namedPlaceholders() {
        let tokens = tokenizer.tokenize("$1 :name @var")
        let placeholders = tokens.filter { $0.type == .placeholder }
        #expect(placeholders.count == 3)
        #expect(placeholders.map(\.value) == ["$1", ":name", "@var"])
    }

    // MARK: - Mixed Input

    @Test("Full SELECT statement tokens")
    func fullSelectStatement() {
        let tokens = tokenizer.tokenize("SELECT id, name FROM users WHERE active = true")
        let nonWS = tokens.filter { $0.type != .whitespace }
        // SELECT id , name FROM users WHERE active = true
        #expect(nonWS.count == 10)
        #expect(nonWS[0] == SQLToken(type: .keyword, value: "SELECT"))
        #expect(nonWS[1] == SQLToken(type: .identifier, value: "id"))
        #expect(nonWS[2] == SQLToken(type: .punctuation, value: ","))
        #expect(nonWS[3] == SQLToken(type: .identifier, value: "name"))
        #expect(nonWS[4] == SQLToken(type: .keyword, value: "FROM"))
        #expect(nonWS[5] == SQLToken(type: .identifier, value: "users"))
        #expect(nonWS[6] == SQLToken(type: .keyword, value: "WHERE"))
        #expect(nonWS[7] == SQLToken(type: .identifier, value: "active"))
        #expect(nonWS[8] == SQLToken(type: .operator, value: "="))
        #expect(nonWS[9] == SQLToken(type: .keyword, value: "true"))
    }

    @Test("Preserves original token values")
    func preservesOriginalValues() {
        let tokens = tokenizer.tokenize("select 'Hello World' from users")
        let nonWS = tokens.filter { $0.type != .whitespace }
        #expect(nonWS[0].value == "select") // preserves original case
        #expect(nonWS[1].value == "'Hello World'")
    }

    // MARK: - Engine grammar

    private func code(_ sql: String, _ type: DatabaseType, operators: Set<String> = []) -> [SQLToken] {
        SQLTokenizer(operators: operators).tokenize(sql, grammar: type.lexicalGrammar).filter { $0.type != .whitespace }
    }

    @Test("A bracket name is one identifier under SQL Server's grammar")
    func bracketIdentifier() {
        #expect(code("select [order id] from [my table]", .mssql).map(\.value) == ["select", "[order id]", "from", "[my table]"])
        #expect(code("[select]", .mssql) == [SQLToken(type: .identifier, value: "[select]")])
    }

    @Test("Without a grammar a bracket stays apart, as the query fingerprint reads it")
    func bracketWithoutGrammar() {
        #expect(tokenizer.tokenize("[users]").map(\.value) == ["[", "users", "]"])
    }

    @Test("A dollar-quoted body is one string")
    func dollarQuotedBody() {
        let body = "$$\nif x:\n    return 1\n$$"
        #expect(code("as \(body) language plpython3u", .postgresql).map(\.value) == ["as", body, "language", "plpython3u"])
    }

    @Test("A GO line is a directive")
    func batchSeparatorDirective() {
        let tokens = code("select 1\nGO\nselect 2", .mssql)
        #expect(tokens.map(\.value) == ["select", "1", "GO", "select", "2"])
        #expect(tokens[2].type == .directive)
    }

    @Test("A DELIMITER line is a directive and its delimiter ends a statement")
    func delimiterDirective() {
        let tokens = code("DELIMITER //\nselect 1; end //\nDELIMITER ;", .mysql)
        #expect(tokens.map(\.value) == ["DELIMITER //", "select", "1", ";", "end", "//", "DELIMITER ;"])
        #expect(tokens.map(\.type) == [.directive, .keyword, .number, .punctuation, .keyword, .punctuation, .directive])
    }

    @Test("DELIMITER is a directive only where a statement starts")
    func delimiterOnlyAtStatementStart() {
        #expect(code("select\ndelimiter as d from t", .mysql).allSatisfy { $0.type != .directive })
        #expect(code("select 1;\ndelimiter $$", .mysql).last?.type == .directive)
    }

    @Test("A MySQL # comment runs to the end of its line")
    func hashComment() {
        #expect(code("a # b and\nc", .mysql).map(\.value) == ["a", "# b and", "c"])
    }

    @Test("A line comment in a CRLF text ends at its line")
    func crlfLineComment() {
        #expect(code("a -- note\r\nb", .mysql).map(\.value) == ["a", "-- note", "b"])
    }

    @Test("Operators the dialect declares stay whole, and T-SQL's <@ is less than a variable")
    func dialectOperators() {
        #expect(code("a@>b and c#>>d", .postgresql, operators: ["@>", "#>>"]).map(\.value) == ["a", "@>", "b", "and", "c", "#>>", "d"])
        #expect(code("a<@b", .mssql).map(\.value) == ["a", "<", "@b"])
        #expect(code("a <=> b, @x := 1", .mysql).map(\.value) == ["a", "<=>", "b", ",", "@x", ":=", "1"])
    }

    @Test("A literal prefix stays on its literal")
    func prefixedLiterals() {
        let tokens = code("0xFF N'abc' X'4D' _utf8mb4'a' 2fa_codes", .mysql)
        #expect(tokens.map(\.value) == ["0xFF", "N'abc'", "X'4D'", "_utf8mb4'a'", "2fa_codes"])
        #expect(tokens.map(\.type) == [.number, .string, .string, .string, .identifier])
    }

    @Test("Without a grammar a word before a quote stays a word, so the fingerprint keeps the column")
    func wordBeforeQuoteWithoutGrammar() {
        for word in ["a", "b", "N"] {
            let tokens = tokenizer.tokenize("SELECT \(word)'alias' FROM t").filter { $0.type != .whitespace }
            #expect(tokens.map(\.value) == ["SELECT", word, "'alias'", "FROM", "t"])
            #expect(tokens[1].type == .identifier)
        }
        for type in [DatabaseType.sqlite, .mysql] {
            #expect(
                SQLQueryFingerprint.hash("SELECT a'alias' FROM t", databaseType: type)
                    != SQLQueryFingerprint.hash("SELECT b'alias' FROM t", databaseType: type)
            )
            #expect(SQLQueryFingerprint.normalize("SELECT a'alias' FROM t", databaseType: type) == "SELECT a ? FROM t")
        }
    }

    @Test("Under a grammar only a literal introducer joins its quote")
    func onlyIntroducersJoinTheirQuote() {
        #expect(code("a'alias' r'raw' b'0101'", .mysql).map(\.value) == ["a", "'alias'", "r", "'raw'", "b'0101'"])
    }

    @Test("An @ parameter may start with a digit")
    func atParameterWithLeadingDigit() {
        let tokens = code("@1 @1ab @@x", .sqlite)
        #expect(tokens.map(\.value) == ["@1", "@1ab", "@@x"])
        #expect(tokens.allSatisfy { $0.type == .placeholder })
    }

    @Test("A custom delimiter splits the word it is glued to")
    func delimiterSplitsAGluedWord() {
        let tokens = code("DELIMITER $$\nend$$\nDELIMITER ;", .mysql)
        #expect(tokens.map(\.value) == ["DELIMITER $$", "end", "$$", "DELIMITER ;"])
        #expect(tokens.map(\.type) == [.directive, .keyword, .punctuation, .directive])
    }

    @Test("Under T-SQL a name continues with # and @; under MySQL # starts a comment")
    func tsqlNameCharacters() {
        #expect(code("Part# a#b c@d", .mssql).map(\.value) == ["Part#", "a#b", "c@d"])
        #expect(code("a#b\nc", .mysql).map(\.value) == ["a", "#b", "c"])
    }

    @Test("Operators no dialect declares stay whole")
    func undeclaredOperators() {
        #expect(code("a += b == c ** d // e ^= f", .sqlite).map(\.value) == ["a", "+=", "b", "==", "c", "**", "d", "//", "e", "^=", "f"])
    }

    @Test("A system variable fingerprints as it did before, apart from a literal")
    func systemVariableFingerprint() {
        #expect(SQLQueryFingerprint.normalize("SELECT @@version", databaseType: .mysql) == "SELECT @ ?")
        #expect(SQLQueryFingerprint.hash("SELECT @@version", databaseType: .mysql) != SQLQueryFingerprint.hash("SELECT 1", databaseType: .mysql))
    }

    @Test("Under a grammar a 0x or 0b run is a number only when its digits are hex or binary")
    func prefixedNumbersNeedTheirDigits() {
        let tokens = code("0xFF 0b101 0bar 0xyz", .mysql)
        #expect(tokens.map(\.value) == ["0xFF", "0b101", "0bar", "0xyz"])
        #expect(tokens.map(\.type) == [.number, .number, .identifier, .identifier])
    }

    @Test("A keyword before a quote stays a keyword")
    func keywordBeforeQuote() {
        #expect(code("then'x'", .mysql).map(\.value) == ["then", "'x'"])
    }

    @Test("Temp tables, variables and $ names are one word")
    func prefixedNames() {
        #expect(code("#tmp ##global @@rowcount @p", .mssql).map(\.value) == ["#tmp", "##global", "@@rowcount", "@p"])
        #expect(code("v$session SYS#1", .oracle).map(\.value) == ["v$session", "SYS#1"])
    }
}

// What the query fingerprint read on main, before the formatter read grammars: its hashes are stored, so the reading
// without a grammar must not move. Each expected shape was produced by main's own SQLTokenizer and SQLQueryFingerprint.
struct SQLFingerprintGoldenTests {
    static let corpus: [(DatabaseType, String, String)] = [
        (.postgresql, "SELECT * FROM t WHERE id = 1", "SELECT * FROM t WHERE id = ?"),
        (.postgresql, "select id, name from users where active = true and role = 'admin'", "SELECT id, name FROM users WHERE active = ? AND role = ?"),
        (.mysql, "SELECT @@version", "SELECT @ ?"),
        (.mysql, "SELECT @@sql_mode", "SELECT @ ?"),
        (.mysql, "SELECT 1", "SELECT ?"),
        (.mssql, "SELECT @@ROWCOUNT, @@ERROR", "SELECT @ ?, @ ?"),
        (.sqlite, "SELECT @1, @1ab FROM t WHERE a = @2", "SELECT ?, ? FROM t WHERE a = ?"),
        (.mssql, "SELECT @x, @y FROM t WHERE a = @p", "SELECT ?, ? FROM t WHERE a = ?"),
        (.mysql, "SELECT apply - 1 FROM t", "SELECT apply - ? FROM t"),
        (.mysql, "SELECT apply + 1 FROM t", "SELECT apply + ? FROM t"),
        (.mysql, "SELECT * FROM apply a", "SELECT * FROM apply a"),
        (.mysql, "SELECT 0bar FROM t", "SELECT ? bar FROM t"),
        (.mysql, "SELECT 0baz FROM t", "SELECT ? baz FROM t"),
        (.mysql, "SELECT 0xFF, 0x1A, 0b101 FROM t", "SELECT ? xFF, ? x1A, ? b101 FROM t"),
        (.mysql, "SELECT 2fa_codes.id FROM 2fa_codes", "SELECT ? fa_codes.id FROM ? fa_codes"),
        (.mssql, "SELECT N'x', N'longer text' FROM t", "SELECT N ?, N ? FROM t"),
        (.mysql, "SELECT X'4D', B'101', _utf8mb4'a' FROM t", "SELECT X ?, B ?, _utf8mb4 ? FROM t"),
        (.mysql, "SELECT a'alias', b'alias' FROM t", "SELECT a ?, b ? FROM t"),
        (.postgresql, "SELECT U&'d\\0061t', E'it\\'s' FROM t", "SELECT U & ?, E ? FROM t"),
        (.oracle, "SELECT q'[it's]' FROM dual", "SELECT q ? s] ?"),
        (.mssql, "SELECT [order id], [group] FROM [my table] WHERE [select] = 1", "SELECT[ORDER id], GROUP FROM[my TABLE] WHERE SELECT = ?"),
        (.mssql, "SELECT * FROM [users]", "SELECT * FROM users"),
        (.mssql, "SELECT * FROM users", "SELECT * FROM users"),
        (.mssql, "SELECT * INTO #tmp FROM t; SELECT * FROM ##global", "SELECT * INTO # tmp FROM t; SELECT * FROM # # global"),
        (.mssql, "SELECT Part# FROM Parts", "SELECT Part # FROM Parts"),
        (.mssql, "SET @x += 1", "SET ? + = ?"),
        (.sqlite, "SELECT * FROM t WHERE a == b", "SELECT * FROM t WHERE a = = b"),
        (.oracle, "SELECT y ** 2 FROM dual WHERE a ^= b", "SELECT y * * ? FROM dual WHERE a ^ = b"),
        (.duckdb, "SELECT 7 // 2", "SELECT ? / / ?"),
        (.mysql, "SELECT a <=> b, @a := 1 FROM t", "SELECT a <= > b, ? : = ? FROM t"),
        (.postgresql, "SELECT $$secret payload$$ FROM t", "SELECT ? FROM t"),
        (.postgresql, "SELECT $tag$body here$tag$ FROM t", "SELECT ? FROM t"),
        (.postgresql, "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql", "CREATE FUNCTION f() RETURNS INT AS ? LANGUAGE plpgsql"),
        (.postgresql, "SELECT a::int, b::text FROM t", "SELECT a :: INT, b :: TEXT FROM t"),
        (.postgresql, "SELECT data->>'name', data->'a', data #>> '{a,b}' FROM t", "SELECT data ->> ?, data -> ?, data # > > ? FROM t"),
        (.postgresql, "SELECT * FROM t WHERE tags @> ARRAY['x'] AND d ?| array['a']", "SELECT * FROM t WHERE tags @ > ARRAY[?] AND d ? | array[?]"),
        (.postgresql, "SELECT * FROM t WHERE name ~* 'abc' AND name !~ 'x'", "SELECT * FROM t WHERE name ~ * ? AND name ! ~ ?"),
        (.postgresql, "SELECT embedding <-> '[1,2,3]' FROM items", "SELECT embedding < -> ? FROM items"),
        (.postgresql, "-- pick\nSELECT * FROM t /* hint */ WHERE id = 1", "SELECT * FROM t WHERE id = ?"),
        (.mysql, "SELECT 1 # comment\nFROM t", "SELECT ? # comment FROM t"),
        (.mysql, "SELECT 5--3", "SELECT ?"),
        (.postgresql, "SELECT 1 /* a /* b */ c */ FROM t", "SELECT ? c * / FROM t"),
        (.postgresql, "select a, b -- note\nfrom t where x = 1", "SELECT a, b FROM t WHERE x = ?"),
        (.mysql, "SELECT /*!40001 SQL_NO_CACHE */ a FROM t", "SELECT a FROM t"),
        (.postgresql, "SELECT * FROM t WHERE id IN (1, 2, 3)", "SELECT * FROM t WHERE id IN (...)"),
        (.postgresql, "SELECT * FROM t WHERE id IN (SELECT id FROM u)", "SELECT * FROM t WHERE id IN (SELECT id FROM u)"),
        (.postgresql, "INSERT INTO t VALUES (1, 'a'), (2, 'b')", "INSERT INTO t VALUES (...)"),
        (.postgresql, "SELECT * FROM t WHERE x = -1 AND y = +2", "SELECT * FROM t WHERE x = ? AND y = ?"),
        (.postgresql, "SELECT b - 1, f(a, -1) FROM t", "SELECT b - ?, f(a, ?) FROM t"),
        (.postgresql, "SELECT tags[1] - 1 FROM t", "SELECT tags[?] - ? FROM t"),
        (.postgresql, "SELECT 0.5, .5, 1e10, 1.5E-3 FROM t", "SELECT ?, ?, ?, ? FROM t"),
        (.mysql, "SELECT * FROM t WHERE n = \"bob\"", "SELECT * FROM t WHERE n = ?"),
        (.postgresql, "SELECT \"email\" FROM \"Users\" WHERE id = 1", "SELECT email FROM Users WHERE id = ?"),
        (.mysql, "SELECT * FROM `users`", "SELECT * FROM users"),
        (.oracle, "SELECT * FROM v$session WHERE sid = 1", "SELECT * FROM v ? WHERE sid = ?"),
        (.oracle, "BEGIN x := 1; END;", "BEGIN x : = ?; END;"),
        (.mssql, "SELECT 1\nGO\nSELECT 2", "SELECT ? GO SELECT ?"),
        (.mysql, "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END //\nDELIMITER ;", "DELIMITER / / CREATE PROCEDURE p() BEGIN SELECT ?; END / / DELIMITER;"),
        (.mysql, "DELIMITER $$\nEND$$", "DELIMITER ?"),
        (.clickhouse, "SELECT database, table FROM system.columns WHERE database = 'default'", "SELECT DATABASE, TABLE FROM system.columns WHERE DATABASE = ?"),
        (.postgresql, "SELECT count(*), sum(total) FROM t GROUP BY 1", "SELECT COUNT(*), SUM(total) FROM t GROUP BY ?"),
        (.postgresql, "SELECT * FROM t WHERE created > now() - interval '1 day'", "SELECT * FROM t WHERE created > now() - INTERVAL ?"),
        (.postgresql, "SELECT 'C:\\', 'hello   world' FROM t", "SELECT ? hello world ?"),
        (.mysql, "SELECT 'it\\'s' FROM t", "SELECT ? FROM t"),
        (.postgresql, "SELECT café, naïve FROM t", "SELECT café, naïve FROM t"),
        (.postgresql, "SELECT * FROM t WHERE id = $1 AND name = :name", "SELECT * FROM t WHERE id = ? AND name = ?"),
        (.postgresql, "SELECT * FROM t WHERE id = ?", "SELECT * FROM t WHERE id = ?"),
        (.postgresql, "UPDATE t SET a = 1, b = 'x' WHERE id = 7", "UPDATE t SET a = ?, b = ? WHERE id = ?"),
        (.postgresql, "DELETE FROM t WHERE id IN (1, 2)", "DELETE FROM t WHERE id IN (...)"),
        (.postgresql, "SELECT CASE WHEN a = 1 THEN 'x' ELSE 'y' END FROM t", "SELECT CASE WHEN a = ? THEN ? ELSE ? END FROM t"),
        (.postgresql, "SELECT * FROM t1 JOIN t2 ON t1.id = t2.id LEFT OUTER JOIN t3 ON t3.id = t1.id", "SELECT * FROM t1 JOIN t2 ON t1.id = t2.id LEFT OUTER JOIN t3 ON t3.id = t1.id"),
        (.mssql, "SELECT * FROM a OUTER APPLY f(a.id) x CROSS APPLY g(a.id) y", "SELECT * FROM a OUTER APPLY f(a.id) x CROSS APPLY g(a.id) y"),
        (.postgresql, "select 'foo'\n'bar' as s", "SELECT ? AS s"),
        (.postgresql, "SELECT a FROM t WHERE b = 'x''y'", "SELECT a FROM t WHERE b = ?"),
    ]

    @Test("Every query fingerprints exactly as it did before the formatter read grammars")
    func fingerprintsMatchMain() {
        for (type, sql, shape) in Self.corpus {
            #expect(SQLQueryFingerprint.normalize(sql, databaseType: type) == shape, "\(type.rawValue): \(sql)")
        }
    }
}
