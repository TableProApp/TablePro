//
//  DotenvParserTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Dotenv Parser")
struct DotenvParserTests {

    private func value(_ source: String, _ key: String, env: [String: String] = [:]) -> String? {
        DotenvParser.parse(source, processEnvironment: env).entry(for: key)?.value
    }

    // MARK: - Inline comments

    @Test("A hash with no preceding space stays in the value")
    func testHashWithoutSpaceIsValue() {
        #expect(value("K=bar#baz", "K") == "bar#baz")
    }

    @Test("A hash after whitespace starts a comment")
    func testHashAfterWhitespaceIsComment() {
        #expect(value("K=bar #baz", "K") == "bar")
        #expect(value("K=bar # baz # other", "K") == "bar")
    }

    @Test("A value may start with a hash")
    func testValueStartingWithHash() {
        #expect(value("K=#c", "K") == "#c")
    }

    @Test("A password containing a hash survives")
    func testPasswordWithHash() {
        #expect(value("DB_PASSWORD=p#ssw0rd", "DB_PASSWORD") == "p#ssw0rd")
    }

    // MARK: - Quoting and escapes

    @Test("Double quotes decode the supported escapes")
    func testDoubleQuoteEscapes() {
        #expect(value(#"K="line1\nline2""#, "K") == "line1\nline2")
        #expect(value(#"K="a\tb""#, "K") == "a\tb")
        #expect(value(#"K="say \"hi\"""#, "K") == "say \"hi\"")
        #expect(value(#"K="a\\b""#, "K") == "a\\b")
    }

    @Test("An unknown escape keeps its backslash")
    func testUnknownEscapePreserved() {
        #expect(value(#"K="a\qb""#, "K") == #"a\qb"#)
    }

    @Test("Single quotes are literal and block interpolation")
    func testSingleQuotesAreLiteral() {
        #expect(value(#"K='raw\nstring'"#, "K") == #"raw\nstring"#)
        #expect(value("A=1\nK='${A}'", "K") == "${A}")
    }

    @Test("A quoted value may span lines")
    func testMultilineQuotedValue() {
        let source = "K=\"line1\nline2\"\nJ=after"
        #expect(value(source, "K") == "line1\nline2")
        #expect(value(source, "J") == "after")
    }

    @Test("A comment after a quoted value is ignored")
    func testTrailingCommentAfterQuotedValue() {
        #expect(value(#"K="value" # note"#, "K") == "value")
    }

    // MARK: - Keys and structure

    @Test("The export prefix is stripped")
    func testExportPrefix() {
        #expect(value("export K=value", "K") == "value")
        #expect(value("export\tK=value", "K") == "value")
    }

    @Test("Keys may contain dots and dashes")
    func testKeyCharacterSet() {
        #expect(value("MY-KEY=value", "MY-KEY") == "value")
        #expect(value("my.key=value", "my.key") == "value")
    }

    @Test("A byte order mark is stripped")
    func testByteOrderMark() {
        #expect(value("\u{FEFF}K=value", "K") == "value")
    }

    @Test("CRLF and lone CR are normalized")
    func testLineEndings() {
        #expect(value("K=value\r\nJ=other", "K") == "value")
        #expect(value("K=value\rJ=other", "J") == "other")
    }

    @Test("The last duplicate key wins")
    func testDuplicateKeyLastWins() {
        #expect(value("K=first\nK=second", "K") == "second")
    }

    @Test("Whitespace around the equals sign is ignored")
    func testWhitespaceAroundEquals() {
        #expect(value("K = value", "K") == "value")
    }

    @Test("An empty value parses as empty")
    func testEmptyValue() {
        #expect(value("K=", "K") == "")
    }

    @Test("A full line comment is skipped")
    func testFullLineComment() {
        #expect(value("# K=nope\nK=yes", "K") == "yes")
    }

    @Test("One malformed line does not abort the file")
    func testMalformedLineRecovery() {
        #expect(value("not a pair\nK=value", "K") == "value")
    }

    // MARK: - Interpolation

    @Test("References resolve against earlier keys and the process environment")
    func testInterpolationSources() {
        #expect(value("A=one\nK=${A}-two", "K") == "one-two")
        #expect(value("A=one\nK=$A-two", "K") == "one-two")
        #expect(value("K=${FROM_ENV}", "K", env: ["FROM_ENV": "outside"]) == "outside")
    }

    @Test("A reference default is used when the name is missing")
    func testInterpolationDefault() {
        #expect(value("K=${MISSING:-fallback}", "K") == "fallback")
    }

    @Test("An unresolved reference is flagged and kept literal")
    func testUnresolvedReferenceFlagged() {
        let document = DotenvParser.parse("K=${NOPE}", processEnvironment: [:])
        #expect(document.entry(for: "K")?.hasUnresolvedReference == true)
        #expect(document.entry(for: "K")?.value == "${NOPE}")
        #expect(document["K"] == nil)
    }

    @Test("A resolved reference is not flagged")
    func testResolvedReferenceNotFlagged() {
        let document = DotenvParser.parse("A=1\nK=${A}", processEnvironment: [:])
        #expect(document.entry(for: "K")?.hasUnresolvedReference == false)
    }

    @Test("Railway style indirection is flagged, not guessed")
    func testRailwayIndirectionFlagged() {
        let document = DotenvParser.parse("K=${{Postgres.DATABASE_URL}}", processEnvironment: [:])
        #expect(document.entry(for: "K")?.hasUnresolvedReference == true)
        #expect(document["K"] == nil)
    }

    // MARK: - Security

    @Test("Command substitution is never executed")
    func testCommandSubstitutionNotExecuted() {
        #expect(value("K=$(whoami)", "K") == "$(whoami)")
        #expect(value(#"K="$(whoami)""#, "K") == "$(whoami)")
        #expect(value("K=`whoami`", "K") == "`whoami`")
    }

    @Test("A URL password containing an at sign is preserved verbatim")
    func testAtSignInValue() {
        let source = "DATABASE_URL=postgres://u:p@ss@host/db"
        #expect(value(source, "DATABASE_URL") == "postgres://u:p@ss@host/db")
    }
}
