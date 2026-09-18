//
//  SQLTokenCursorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL token cursor")
struct SQLTokenCursorTests {
    private static func tokens(_ sql: String, rules: SQLLexicalRules) -> [SQLTokenCursor.Token] {
        var cursor = SQLTokenCursor(sql, rules: rules)
        var read: [SQLTokenCursor.Token] = []
        while let token = cursor.next() {
            read.append(token)
        }
        return read
    }

    private static func words(_ sql: String, rules: SQLLexicalRules) -> [String] {
        tokens(sql, rules: rules).compactMap(\.word)
    }

    private static let mysql = SQLLexicalRules(dialect: .mysql)
    private static let postgres = SQLLexicalRules(dialect: .postgres)
    private static let sqlite = SQLLexicalRules(dialect: .sqlite)

    @Test("A line comment is skipped")
    func lineCommentIsSkipped() {
        #expect(Self.words("-- nightly\nVACUUM t", rules: Self.postgres) == ["VACUUM", "T"])
    }

    @Test("A hash line comment is skipped on MySQL and read as a symbol elsewhere")
    func hashCommentIsMySQLOnly() {
        #expect(Self.words("# note\nSET sql_log_bin = 0", rules: Self.mysql) == ["SET", "SQL_LOG_BIN", "0"])
        #expect(Self.words("# note\nSET sql_log_bin = 0", rules: Self.postgres) == ["NOTE", "SET", "SQL_LOG_BIN", "0"])
    }

    @Test("A nested block comment is skipped whole on PostgreSQL")
    func nestedBlockCommentIsSkipped() {
        #expect(Self.words("/* outer /* inner */ still */ VACUUM", rules: Self.postgres) == ["VACUUM"])
    }

    @Test("A MySQL conditional comment carries code, so its body is read")
    func conditionalCommentBodyIsRead() {
        #expect(
            Self.words("/*!40101 SET @@SESSION.SQL_LOG_BIN= 0 */", rules: Self.mysql)
                == ["SET", "@@SESSION", "SQL_LOG_BIN", "0"]
        )
        #expect(
            Self.words("/*M!100100 START TRANSACTION */", rules: Self.mysql)
                == ["START", "TRANSACTION"]
        )
    }

    @Test("A conditional comment is an ordinary comment on every other dialect")
    func conditionalCommentIsSkippedElsewhere() {
        #expect(Self.words("/*!40101 SET sql_log_bin = 0 */ VACUUM", rules: Self.postgres) == ["VACUUM"])
    }

    @Test("Reading stops at a semicolon that is not inside parentheses")
    func semicolonEndsTheStatement() {
        #expect(Self.words("VACUUM; DROP TABLE t", rules: Self.postgres) == ["VACUUM"])
    }

    @Test("A string is a literal, and an identifier keeps the text it quotes")
    func quotingIsClassified() {
        #expect(Self.tokens("'VACUUM'", rules: Self.postgres) == [.literal])
        #expect(Self.tokens("$$VACUUM$$", rules: Self.postgres) == [.literal])
        #expect(Self.tokens("E'a\\'b'", rules: Self.postgres) == [.literal])
        #expect(Self.tokens("\"x\"", rules: Self.postgres) == [.quotedIdentifier("x")])
        #expect(Self.tokens("`x`", rules: Self.mysql) == [.quotedIdentifier("x")])
    }

    @Test("Brackets quote an identifier only where the rules say they do")
    func bracketsFollowTheRules() {
        let bracketed = SQLLexicalRules(dialect: .generic, backslashEscapes: false, bracketsDelimitIdentifiers: true)
        #expect(Self.tokens("[Sales Db]", rules: bracketed) == [.quotedIdentifier("Sales Db")])
        #expect(Self.words("[Sales Db]", rules: Self.postgres) == ["SALES", "DB"])
    }

    @Test("A doubled delimiter inside a quoted identifier is one character")
    func doubledDelimiterIsUnescaped() {
        #expect(Self.tokens("\"a\"\"b\"", rules: Self.postgres) == [.quotedIdentifier("a\"b")])
    }

    @Test("MySQL's assignment operator reads as an equals sign")
    func colonEqualsReadsAsEquals() {
        var cursor = SQLTokenCursor("sql_log_bin := 0", rules: Self.mysql)
        #expect(cursor.next()?.word == "SQL_LOG_BIN")
        #expect(cursor.next()?.isSymbol(SQLTokenCursor.equals) == true)
    }

    @Test("A scope prefix, its dot and its variable are three tokens")
    func scopePrefixIsSeparateFromItsVariable() {
        #expect(
            Self.tokens("@@SESSION . sql_log_bin", rules: Self.mysql) == [
                .word("@@SESSION"),
                .symbol(SQLTokenCursor.period),
                .word("SQL_LOG_BIN")
            ]
        )
    }

    @Test("Parenthesis depth counts up and down")
    func parenthesisDepthIsTracked() {
        var cursor = SQLTokenCursor("PRAGMA journal_mode(WAL)", rules: Self.sqlite)
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
        #expect(Self.words("CALL p('a;b') FROM t", rules: Self.mysql) == ["CALL", "P", "FROM", "T"])
    }

    @Test("Looking ahead leaves the cursor where it was")
    func peekDoesNotAdvance() {
        var cursor = SQLTokenCursor("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", rules: Self.mysql)
        #expect(cursor.next()?.word == "SET")
        #expect(cursor.peek()?.word == "TRANSACTION")
        #expect(cursor.peek()?.word == "TRANSACTION")
        #expect(cursor.next()?.word == "TRANSACTION")
    }
}
