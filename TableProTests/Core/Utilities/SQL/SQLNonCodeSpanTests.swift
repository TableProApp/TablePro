//
//  SQLNonCodeSpanTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL non-code spans")
struct SQLNonCodeSpanTests {
    private func end(
        _ text: String,
        at index: Int = 0,
        rules: SQLLexicalRules = SQLLexicalRules(dialect: .mysql)
    ) -> Int? {
        SQLNonCodeSpan.end(at: index, in: text as NSString, rules: rules)
    }

    @Test("Code is not a span")
    func codeIsNotASpan() {
        #expect(end("SELECT 1") == nil)
        #expect(end("E'x'", rules: SQLLexicalRules(dialect: .mysql)) == nil)
    }

    @Test("Comments run to their end")
    func comments() {
        #expect(end("-- a\nSELECT") == 4)
        #expect(end("# a\nSELECT") == 3)
        #expect(end("# a\nSELECT", rules: SQLLexicalRules(dialect: .postgres)) == nil)
        #expect(end("/* a */ SELECT") == 7)
        #expect(end("/* a /* b */ c */ x", rules: SQLLexicalRules(dialect: .postgres)) == 17)
    }

    @Test("A MySQL conditional comment is code")
    func conditionalComment() {
        #expect(end("/*!40101 SET NAMES utf8 */") == nil)
    }

    @Test("Quoted text honours the engine's escape rules")
    func quotedText() {
        let backslash = SQLLexicalRules(dialect: .generic, backslashEscapes: true, bracketsDelimitIdentifiers: false)
        #expect(end("'it''s' x") == 7)
        #expect(end("'a\\'b' x", rules: backslash) == 6)
        #expect(end("'a\\'b' x", rules: SQLLexicalRules(dialect: .postgres)) == 4)
        #expect(end("`a b` x") == 5)
    }

    @Test("A PostgreSQL escape string starts at its E prefix")
    func escapeString() {
        let postgres = SQLLexicalRules(dialect: .postgres)
        #expect(end("E'a\\'b' x", rules: postgres) == 7)
        #expect(end("xE'a'", at: 1, rules: postgres) == nil)
    }

    @Test("Bracketed identifiers and dollar-quoted bodies are spans where the engine has them")
    func bracketsAndDollarQuotes() {
        let sqlite = SQLLexicalRules(dialect: .sqlite, backslashEscapes: false, bracketsDelimitIdentifiers: true)
        #expect(end("[a]]b] x", rules: sqlite) == 6)
        #expect(end("[a] x") == nil)
        #expect(end("$$a b$$ x", rules: SQLLexicalRules(dialect: .postgres)) == 7)
        #expect(end("$$a b$$ x") == nil)
    }
}
