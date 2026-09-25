//
//  SQLTokenCursorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

struct SQLTokenCursorTests {
    private static func tokens(_ sql: String, grammar: SQLLexicalGrammar) -> [SQLTokenCursor.Token] {
        var cursor = SQLTokenCursor(sql, grammar: grammar)
        var read: [SQLTokenCursor.Token] = []
        while let token = cursor.next() {
            read.append(token)
        }
        return read
    }

    private static func words(_ sql: String, grammar: SQLLexicalGrammar) -> [String] {
        tokens(sql, grammar: grammar).compactMap(\.word)
    }

    @Test("A line comment is skipped")
    func lineCommentIsSkipped() {
        #expect(Self.words("-- nightly\nVACUUM t", grammar: TestGrammar.postgres) == ["VACUUM", "T"])
    }

    @Test("A hash line comment is skipped on MySQL and read as a symbol elsewhere")
    func hashCommentIsMySQLOnly() {
        #expect(Self.words("# note\nSET sql_log_bin = 0", grammar: TestGrammar.mysql) == ["SET", "SQL_LOG_BIN", "0"])
        #expect(Self.words("# note\nSET sql_log_bin = 0", grammar: TestGrammar.postgres) == ["NOTE", "SET", "SQL_LOG_BIN", "0"])
    }

    @Test("A nested block comment is skipped whole on PostgreSQL")
    func nestedBlockCommentIsSkipped() {
        #expect(Self.words("/* outer /* inner */ still */ VACUUM", grammar: TestGrammar.postgres) == ["VACUUM"])
    }

    @Test("A MySQL conditional comment carries code, so its body is read")
    func conditionalCommentBodyIsRead() {
        #expect(
            Self.words("/*!40101 SET @@SESSION.SQL_LOG_BIN= 0 */", grammar: TestGrammar.mysql)
                == ["SET", "@@SESSION", "SQL_LOG_BIN", "0"]
        )
        #expect(
            Self.words("/*M!100100 START TRANSACTION */", grammar: TestGrammar.mysql)
                == ["START", "TRANSACTION"]
        )
    }

    @Test("A conditional comment is an ordinary comment on every other dialect")
    func conditionalCommentIsSkippedElsewhere() {
        #expect(Self.words("/*!40101 SET sql_log_bin = 0 */ VACUUM", grammar: TestGrammar.postgres) == ["VACUUM"])
    }

    @Test("Reading stops at a semicolon that is not inside parentheses")
    func semicolonEndsTheStatement() {
        #expect(Self.words("VACUUM; DROP TABLE t", grammar: TestGrammar.postgres) == ["VACUUM"])
    }

    @Test("A string is a literal, and an identifier keeps the text it quotes")
    func quotingIsClassified() {
        #expect(Self.tokens("'VACUUM'", grammar: TestGrammar.postgres) == [.literal])
        #expect(Self.tokens("$$VACUUM$$", grammar: TestGrammar.postgres) == [.literal])
        #expect(Self.tokens("E'a\\'b'", grammar: TestGrammar.postgres) == [.literal])
        #expect(Self.tokens("\"x\"", grammar: TestGrammar.postgres) == [.quotedIdentifier("x")])
        #expect(Self.tokens("`x`", grammar: TestGrammar.mysql) == [.quotedIdentifier("x")])
    }

    @Test("Brackets quote an identifier only where the rules say they do")
    func bracketsFollowTheRules() {
        let bracketed = TestGrammar.standard.union(.bracketQuotedIdentifiers)
        #expect(Self.tokens("[Sales Db]", grammar: bracketed) == [.quotedIdentifier("Sales Db")])
        #expect(Self.words("[Sales Db]", grammar: TestGrammar.postgres) == ["SALES", "DB"])
    }

    @Test("A doubled delimiter inside a quoted identifier is one character")
    func doubledDelimiterIsUnescaped() {
        #expect(Self.tokens("\"a\"\"b\"", grammar: TestGrammar.postgres) == [.quotedIdentifier("a\"b")])
    }

    @Test("MySQL's assignment operator reads as an equals sign")
    func colonEqualsReadsAsEquals() {
        var cursor = SQLTokenCursor("sql_log_bin := 0", grammar: TestGrammar.mysql)
        #expect(cursor.next()?.word == "SQL_LOG_BIN")
        #expect(cursor.next()?.isSymbol(SQLTokenCursor.equals) == true)
    }

    @Test("A scope prefix, its dot and its variable are three tokens")
    func scopePrefixIsSeparateFromItsVariable() {
        #expect(
            Self.tokens("@@SESSION . sql_log_bin", grammar: TestGrammar.mysql) == [
                .word("@@SESSION"),
                .symbol(SQLTokenCursor.period),
                .word("SQL_LOG_BIN")
            ]
        )
    }

    @Test("Parenthesis depth counts up and down")
    func parenthesisDepthIsTracked() {
        var cursor = SQLTokenCursor("PRAGMA journal_mode(WAL)", grammar: TestGrammar.sqlite)
        #expect(cursor.next()?.word == "PRAGMA")
        #expect(cursor.parenDepth == 0)
        #expect(cursor.next()?.word == "JOURNAL_MODE")
        #expect(cursor.next()?.isSymbol(SQLTokenCursor.openParen) == true)
        #expect(cursor.parenDepth == 1)
        #expect(cursor.next()?.word == "WAL")
        #expect(cursor.next()?.isSymbol(SQLTokenCursor.closeParen) == true)
        #expect(cursor.parenDepth == 0)
    }

    @Test("A semicolon inside parentheses does not end the statement")
    func semicolonInsideParenthesesIsRead() {
        #expect(Self.words("CALL p('a;b') FROM t", grammar: TestGrammar.mysql) == ["CALL", "P", "FROM", "T"])
    }

    @Test("Looking ahead leaves the cursor where it was")
    func peekDoesNotAdvance() {
        var cursor = SQLTokenCursor("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", grammar: TestGrammar.mysql)
        #expect(cursor.next()?.word == "SET")
        #expect(cursor.peek()?.word == "TRANSACTION")
        #expect(cursor.peek()?.word == "TRANSACTION")
        #expect(cursor.next()?.word == "TRANSACTION")
    }

    @Test("An Oracle q-quote reads as one literal")
    func alternativeQuoteIsOneLiteral() {
        let tokens = Self.tokens("SELECT q'[it's; ok]' FROM dual", grammar: TestGrammar.oracle)
        #expect(tokens == [.word("SELECT"), .literal, .word("FROM"), .word("DUAL")])
    }

    @Test("The location is just past the last token read, and stays on a depth-0 semicolon")
    func locationFollowsTheTokens() {
        var cursor = SQLTokenCursor("f(a, 'b,c'), d; e", grammar: TestGrammar.postgres)
        var commas: [Int] = []
        while let token = cursor.next() {
            if token.isSymbol(SQLTokenCursor.comma), cursor.parenDepth == 0 { commas.append(cursor.location - 1) }
        }
        #expect(commas == [11])
        #expect(cursor.location == 14)
    }
}
