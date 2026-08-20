//
//  SqlLexerTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SQL lexer")
struct SqlLexerTests {

    @Test("A line comment runs to the newline, not past it")
    func endOfLineStopsAtNewline() {
        let text = "SELECT 1 -- note\nSELECT 2" as NSString
        #expect(SqlLexer.endOfLine(text, from: 9, length: text.length) == 16)
    }

    @Test("An offset past the end clamps instead of trapping")
    func endOfLineClamps() {
        let text = "abc" as NSString
        #expect(SqlLexer.endOfLine(text, from: 99, length: text.length) == 3)
    }

    @Test("A block comment runs past its terminator and counts the lines it crossed")
    func blockCommentSpansLines() {
        let text = "/* a\nb */x" as NSString
        let span = SqlLexer.skipBlockComment(text, from: 0, length: text.length)
        #expect(span.next == 9)
        #expect(span.newlines == 1)
    }

    @Test("An unterminated block comment stops at the end of the document")
    func unterminatedBlockComment() {
        let text = "/* a\nb" as NSString
        #expect(SqlLexer.skipBlockComment(text, from: 0, length: text.length).next == text.length)
    }

    @Test("A doubled quote escapes in every dialect")
    func doubledQuoteEscapes() {
        let text = "'it''s' x" as NSString
        for dialect in SqlDialect.allCases {
            let span = SqlLexer.skipQuotedString(
                text,
                from: 0,
                quote: SqlLexer.singleQuote,
                length: text.length,
                dialect: dialect
            )
            #expect(span.next == 7, "\(dialect) must treat a doubled quote as an escape")
        }
    }

    @Test("A backslash escapes only where the dialect says it does")
    func backslashEscapeIsDialectGated() {
        let text = "'a\\' , 'b'" as NSString
        let mysql = SqlLexer.skipQuotedString(
            text,
            from: 0,
            quote: SqlLexer.singleQuote,
            length: text.length,
            dialect: .mysql
        )
        let postgres = SqlLexer.skipQuotedString(
            text,
            from: 0,
            quote: SqlLexer.singleQuote,
            length: text.length,
            dialect: .postgres
        )
        #expect(postgres.next == 4, "PostgreSQL ends the string at the quote after the backslash")
        #expect(mysql.next > postgres.next, "MySQL treats the backslash as an escape and reads further")
    }

    @Test("An unterminated string stops at the end of the document")
    func unterminatedString() {
        let text = "'abc" as NSString
        let span = SqlLexer.skipQuotedString(
            text,
            from: 0,
            quote: SqlLexer.singleQuote,
            length: text.length,
            dialect: .generic
        )
        #expect(span.next == text.length)
    }

    @Test("A dollar quoted body reports where the body stops and where the tag ends")
    func dollarQuotedBody() {
        let text = "$$a\nb$$;" as NSString
        let result = SqlLexer.skipDollarQuotedBody(text, from: 2, tag: "", length: text.length)
        #expect(result.bodyEnd == 5)
        #expect(result.span.next == 7)
        #expect(result.span.newlines == 1)
    }

    @Test("Comment openers are recognised, and a MySQL conditional comment is distinguished")
    func commentOpeners() {
        let line = "-- x" as NSString
        let block = "/* x */" as NSString
        let conditional = "/*! x */" as NSString

        #expect(SqlLexer.startsLineComment(line, at: 0, length: line.length))
        #expect(SqlLexer.startsBlockComment(block, at: 0, length: block.length))
        #expect(!SqlLexer.startsConditionalComment(block, at: 0, length: block.length))
        #expect(SqlLexer.startsConditionalComment(conditional, at: 0, length: conditional.length))
    }

    @Test("Whitespace and quote classification match the characters they name")
    func classification() {
        #expect(SqlLexer.isWhitespace(SqlLexer.space))
        #expect(SqlLexer.isWhitespace(SqlLexer.newline))
        #expect(!SqlLexer.isWhitespace(SqlLexer.semicolon))
        #expect(SqlLexer.isQuote(SqlLexer.backtick))
        #expect(!SqlLexer.isQuote(SqlLexer.dash))
    }
}
