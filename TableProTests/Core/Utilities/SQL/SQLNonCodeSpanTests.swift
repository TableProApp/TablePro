//
//  SQLNonCodeSpanTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

@Suite("SQL non-code spans")
struct SQLNonCodeSpanTests {
    private func end(
        _ text: String,
        at index: Int = 0,
        grammar: SQLLexicalGrammar = TestGrammar.mysql
    ) -> Int? {
        SQLNonCodeSpan.end(at: index, in: text as NSString, grammar: grammar)
    }

    @Test("Code is not a span")
    func codeIsNotASpan() {
        #expect(end("SELECT 1") == nil)
        #expect(end("E'x'", grammar: TestGrammar.mysql) == nil)
    }

    @Test("Comments run to their end")
    func comments() {
        #expect(end("-- a\nSELECT") == 4)
        #expect(end("# a\nSELECT") == 3)
        #expect(end("# a\nSELECT", grammar: TestGrammar.postgres) == nil)
        #expect(end("/* a */ SELECT") == 7)
        #expect(end("/* a /* b */ c */ x", grammar: TestGrammar.postgres) == 17)
    }

    @Test("A MySQL conditional comment is code")
    func conditionalComment() {
        #expect(end("/*!40101 SET NAMES utf8 */") == nil)
    }

    @Test("Quoted text honours the engine's escape rules")
    func quotedText() {
        let backslash = TestGrammar.standard.union(.backslashEscapesInSingleQuotes)
        #expect(end("'it''s' x") == 7)
        #expect(end("'a\\'b' x", grammar: backslash) == 6)
        #expect(end("'a\\'b' x", grammar: TestGrammar.postgres) == 4)
        #expect(end("`a b` x") == 5)
    }

    @Test("A PostgreSQL escape string starts at its E prefix")
    func escapeString() {
        let postgres = TestGrammar.postgres
        #expect(end("E'a\\'b' x", grammar: postgres) == 7)
        #expect(end("xE'a'", at: 1, grammar: postgres) == nil)
    }

    @Test("Bracketed identifiers and dollar-quoted bodies are spans where the engine has them")
    func bracketsAndDollarQuotes() {
        let bracketed = TestGrammar.standard.union([.bracketQuotedIdentifiers, .doubledClosingBracketEscapes])
        #expect(end("[a]]b] x", grammar: bracketed) == 6)
        #expect(end("[a] x") == nil)
        #expect(end("$$a b$$ x", grammar: TestGrammar.postgres) == 7)
        #expect(end("$$a b$$ x") == nil)
    }

    @Test("An Oracle q-quote is one literal on Oracle only")
    func alternativeQuoteIsOracleOnly() {
        let oracle = TestGrammar.oracle
        #expect(end("q'[it's]' x", grammar: oracle) == 9)
        #expect(end("xq'[a]'", at: 1, grammar: oracle) == nil)
        #expect(end("q'[it's]' x", grammar: TestGrammar.standard) == nil)
    }
}
