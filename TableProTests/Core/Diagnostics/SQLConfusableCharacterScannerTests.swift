//
//  SQLConfusableCharacterScannerTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Confusable SQL characters")
struct SQLConfusableCharacterScannerTests {
    private func scan(_ text: String, _ dialect: SqlDialect) -> [ConfusableSQLCharacterMatch] {
        scan(text, SQLLexicalRules(dialect: dialect))
    }

    private func scan(_ text: String, _ rules: SQLLexicalRules) -> [ConfusableSQLCharacterMatch] {
        SQLConfusableCharacterScanner.scan(text as NSString, rules: rules)
    }

    private func ranges(_ text: String, _ dialect: SqlDialect) -> [NSRange] {
        scan(text, dialect).map(\.range)
    }

    private func ranges(_ text: String, _ rules: SQLLexicalRules) -> [NSRange] {
        scan(text, rules).map(\.range)
    }

    private func range(of needle: String, in text: String, fromEnd: Bool = false) -> NSRange {
        (text as NSString).range(of: needle, options: fromEnd ? [.literal, .backwards] : .literal)
    }

    // MARK: - Flagged outside literals

    @Test("A full-width semicolon is flagged wherever it ends a statement", arguments: SqlDialect.allCases)
    func fullWidthSemicolon(dialect: SqlDialect) {
        let text = "SELECT 1\u{FF1B}\nSELECT 2\u{FF1B}"
        let matches = scan(text, dialect)
        #expect(matches.map(\.range) == [
            NSRange(location: 8, length: 1),
            NSRange(location: 18, length: 1)
        ])
        #expect(matches.allSatisfy { $0.character == .fullWidthPunctuation("\u{FF1B}") })
    }

    @Test("Full-width commas and parentheses are flagged", arguments: SqlDialect.allCases)
    func fullWidthCommaAndParentheses(dialect: SqlDialect) {
        let text = "SELECT COUNT\u{FF08}*\u{FF09}\u{FF0C} id FROM t"
        #expect(ranges(text, dialect) == [
            NSRange(location: 12, length: 1),
            NSRange(location: 14, length: 1),
            NSRange(location: 15, length: 1)
        ])
    }

    @Test("Curly quotes around a value are flagged", arguments: SqlDialect.allCases)
    func curlyQuotes(dialect: SqlDialect) {
        let text = "SELECT * FROM t WHERE name = \u{2018}Bob\u{2019} OR note = \u{201C}x\u{201D}"
        let matches = scan(text, dialect)
        #expect(matches.map(\.character) == [
            .curlyQuote("\u{2018}"), .curlyQuote("\u{2019}"), .curlyQuote("\u{201C}"), .curlyQuote("\u{201D}")
        ])
    }

    @Test("Every non-ASCII space between tokens is flagged", arguments: [
        0x00A0, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x202F, 0x205F, 0x3000
    ])
    func nonASCIISpaces(value: UInt32) throws {
        let space = try #require(Unicode.Scalar(value))
        let text = "SELECT *\(Character(space))FROM t"
        let matches = scan(text, .mysql)
        #expect(matches == [
            ConfusableSQLCharacterMatch(character: .nonASCIISpace(space), range: NSRange(location: 8, length: 1))
        ])
    }

    @Test("A run of the same character is one warning")
    func runsMerge() {
        let text = "SELECT *\u{3000}\u{3000}\u{3000}FROM t\u{FF1B}\u{FF1B}"
        #expect(ranges(text, .postgres) == [
            NSRange(location: 8, length: 3),
            NSRange(location: 17, length: 2)
        ])
    }

    @Test("Different characters side by side are separate warnings")
    func differentCharactersStaySeparate() {
        #expect(ranges("SELECT \u{FF08}\u{FF09}", .sqlite) == [
            NSRange(location: 7, length: 1),
            NSRange(location: 8, length: 1)
        ])
    }

    // MARK: - Never flagged inside literals, identifiers and comments

    @Test("Characters inside quoted text and comments are left alone", arguments: SqlDialect.allCases)
    func quotedTextAndCommentsAreQuiet(dialect: SqlDialect) {
        let texts = [
            "SELECT '\u{4F60}\u{597D}\u{FF0C}\u{4E16}\u{754C}\u{FF1B}' FROM t",
            "SELECT \"\u{540D}\u{524D}\u{FF08}\u{65E7}\u{FF09}\" FROM t",
            "SELECT `\u{540D}\u{FF1B}` FROM t",
            "SELECT 1 -- \u{FF1B}\u{3000}\u{201C}",
            "SELECT 1 /* \u{FF08}\u{00A0}\u{2019} */",
            "SELECT '\u{2018}quoted\u{2019}'"
        ]
        for text in texts {
            #expect(scan(text, dialect).isEmpty, "\(dialect) flagged \(text)")
        }
    }

    @Test("An unquoted identifier in another script is left alone", arguments: SqlDialect.allCases)
    func nativeScriptIdentifiers(dialect: SqlDialect) {
        #expect(scan("SELECT \u{540D}\u{524D} FROM \u{9867}\u{5BA2}", dialect).isEmpty)
        #expect(scan("SELECT * FROM \u{58F2}\u{4E0A}\u{FF12}\u{FF10}\u{FF12}\u{FF14}", dialect).isEmpty)
        #expect(scan("SELECT caf\u{00E9}\u{FF3F}\u{FF11}", dialect).isEmpty)
    }

    @Test("Full-width letters and digits outside another script are flagged as one word")
    func fullWidthWords() {
        let keyword = "\u{FF33}\u{FF25}\u{FF2C}\u{FF25}\u{FF23}\u{FF34} 1"
        #expect(scan(keyword, .mysql) == [
            ConfusableSQLCharacterMatch(
                character: .fullWidthText(asciiSpelling: "SELECT"),
                range: NSRange(location: 0, length: 6)
            )
        ])

        let digit = "SELECT * FROM t WHERE id = \u{FF11}"
        #expect(scan(digit, .postgres) == [
            ConfusableSQLCharacterMatch(
                character: .fullWidthText(asciiSpelling: "1"),
                range: range(of: "\u{FF11}", in: digit)
            )
        ])

        let mixed = "SELECT user\u{FF3F}\u{FF49}d FROM t"
        #expect(scan(mixed, .sqlite) == [
            ConfusableSQLCharacterMatch(
                character: .fullWidthText(asciiSpelling: "_i"),
                range: range(of: "\u{FF3F}\u{FF49}", in: mixed)
            )
        ])
    }

    // MARK: - MySQL

    @Test("MySQL: a hash comment is quiet and a conditional comment is read as code")
    func mysqlComments() {
        #expect(scan("SELECT 1 # \u{FF1B}", .mysql).isEmpty)
        let conditional = "SELECT 1 /*!50000 \u{FF1B}*/"
        #expect(ranges(conditional, .mysql) == [range(of: "\u{FF1B}", in: conditional)])
    }

    @Test("MySQL: a backslash keeps the string open")
    func mysqlBackslashEscape() {
        let text = "SELECT 'it\\'s\u{FF1B}' \u{FF1B}"
        #expect(ranges(text, .mysql) == [range(of: "\u{FF1B}", in: text, fromEnd: true)])
    }

    // MARK: - PostgreSQL

    @Test("PostgreSQL: a dollar-quoted body is quiet and the text after it is not")
    func postgresDollarQuotes() {
        let text = "CREATE FUNCTION f() RETURNS int AS $fn$ SELECT 1\u{FF1B} $fn$ LANGUAGE sql\u{FF1B}"
        #expect(ranges(text, .postgres) == [range(of: "\u{FF1B}", in: text, fromEnd: true)])
        #expect(scan("SELECT $$\u{FF08}\u{3000}\u{201C}$$", .postgres).isEmpty)
    }

    @Test("PostgreSQL: a dollar sign opens no body in another dialect")
    func dollarQuotesArePostgresOnly() {
        #expect(ranges("SELECT $$\u{FF1B}$$", .mysql) == [NSRange(location: 9, length: 1)])
    }

    @Test("PostgreSQL: a backslash escapes only inside an E string")
    func postgresEscapeStrings() {
        let escaped = "SELECT E'it\\'s\u{FF1B}' \u{FF1B}"
        #expect(ranges(escaped, .postgres) == [range(of: "\u{FF1B}", in: escaped, fromEnd: true)])

        let plain = "SELECT 'a\\' \u{FF1B}"
        #expect(ranges(plain, .postgres) == [range(of: "\u{FF1B}", in: plain)])
    }

    @Test("PostgreSQL: a nested block comment stays a comment until its last terminator")
    func postgresNestedComments() {
        let text = "SELECT 1 /* a /* b */ \u{FF08} */ \u{FF1B}"
        #expect(ranges(text, .postgres) == [range(of: "\u{FF1B}", in: text)])
        #expect(ranges(text, .mysql).count == 2)
    }

    @Test("PostgreSQL: a hash starts no comment")
    func postgresHashIsNotAComment() {
        #expect(ranges("SELECT 1 # \u{FF1B}", .postgres) == [NSRange(location: 11, length: 1)])
    }

    // MARK: - SQLite

    @Test("SQLite: quoted identifiers and comments are quiet, a hash is not a comment")
    func sqliteLexing() {
        #expect(scan("SELECT \"col\u{FF1B}\", `a\u{FF0C}b` FROM t -- \u{FF1B}\n/* \u{3000} */", .sqlite).isEmpty)
        #expect(ranges("SELECT 1 # \u{FF1B}", .sqlite) == [NSRange(location: 11, length: 1)])
        #expect(ranges("SELECT 1\u{FF1B}", .sqlite) == [NSRange(location: 8, length: 1)])
    }

    // MARK: - Bracketed identifiers

    @Test("Bracketed identifiers are quiet only where brackets quote identifiers")
    func bracketedIdentifiers() {
        let text = "SELECT [\u{4EF7}\u{683C}\u{FF08}\u{5143}\u{FF09}], [a]]\u{FF1B}] FROM t\u{FF1B}"
        let bracketRules = SQLLexicalRules(dialect: .generic, backslashEscapes: false, bracketsDelimitIdentifiers: true)
        #expect(ranges(text, bracketRules) == [range(of: "\u{FF1B}", in: text, fromEnd: true)])
        #expect(ranges(text, .generic).count == 4)
    }

    // MARK: - Backslash escapes

    @Test("A backslash keeps the string open wherever the engine escapes with one")
    func backslashEscapesFollowTheEngine() {
        let escaping = SQLLexicalRules(dialect: .generic, backslashEscapes: true, bracketsDelimitIdentifiers: false)

        let quoted = "SELECT 'a\\'b', '\u{4E2D}\u{6587}\u{FF0C}'"
        #expect(scan(quoted, escaping).isEmpty)
        #expect(ranges(quoted, .generic) == [range(of: "\u{FF0C}", in: quoted)])

        let trailing = "SELECT 'it\\'s' FROM t\u{FF1B}"
        #expect(ranges(trailing, escaping) == [range(of: "\u{FF1B}", in: trailing)])
        #expect(scan(trailing, .generic).isEmpty)
    }

    // MARK: - Messages

    @Test("The message names the character and its ASCII counterpart")
    func messages() {
        #expect(
            ConfusableSQLCharacter.fullWidthPunctuation("\u{FF1B}").message
                == "Full-width semicolon (U+FF1B). SQL reads only ; as a statement separator."
        )
        #expect(
            ConfusableSQLCharacter.fullWidthPunctuation("\u{FF0C}").message
                == "Full-width comma (U+FF0C). SQL needs the ASCII comma (U+002C)."
        )
        #expect(
            ConfusableSQLCharacter.fullWidthPunctuation("\u{FF08}").message
                == "Full-width left parenthesis (U+FF08). SQL needs the ASCII left parenthesis (U+0028)."
        )
        #expect(
            ConfusableSQLCharacter.curlyQuote("\u{201C}").message
                == "Curly quote (U+201C). SQL needs the straight quote (U+0022)."
        )
        #expect(
            ConfusableSQLCharacter.curlyQuote("\u{2019}").message
                == "Curly quote (U+2019). SQL needs the straight quote (U+0027)."
        )
        #expect(
            ConfusableSQLCharacter.nonASCIISpace("\u{3000}").message
                == "Non-ASCII space (U+3000). SQL needs an ASCII space (U+0020)."
        )
        #expect(
            ConfusableSQLCharacter.fullWidthText(asciiSpelling: "SELECT").message
                == "Full-width letters or digits. SQL needs the ASCII SELECT."
        )
    }

    @Test("Every full-width punctuation mark has a name of its own")
    func everyPunctuationMarkIsNamed() {
        for value in UInt32(0xFF01)...UInt32(0xFF5E) {
            guard let unit = UInt16(exactly: value), let scalar = Unicode.Scalar(value),
                  !ConfusableSQLCharacter.isFullWidthWordUnit(unit) else { continue }
            let message = ConfusableSQLCharacter.fullWidthPunctuation(scalar).message
            let ascii = String(Character(Unicode.Scalar(value - 0xFEE0) ?? " "))
            #expect(!message.contains("ASCII \(ascii) ("), "U+\(String(value, radix: 16)) has no name")
        }
    }
}

@MainActor
@Suite("Confusable SQL characters in the editor's diagnostics")
struct SQLConfusableCharacterDiagnosticsTests {
    @Test("A confusable character is a warning, and a stray closer is still an error")
    func severities() {
        let diagnostics = QueryDiagnosticsFactory.make(for: .mysql).diagnostics(for: "SELECT 1)\u{FF1B}")
        #expect(diagnostics.map(\.severity) == [.error, .warning])
        #expect(diagnostics.map(\.range) == [NSRange(location: 8, length: 1), NSRange(location: 9, length: 1)])
    }

    @Test("A document at the length limit is checked, and one past it is not")
    func lengthLimit() {
        let producer = SQLConfusableCharacterDiagnosticsProducer(rules: SQLLexicalRules(dialect: .mysql))
        let atLimit = String(repeating: "a", count: 99_999) + "\u{FF1B}"
        let pastLimit = String(repeating: "a", count: 100_000) + "\u{FF1B}"
        #expect(producer.diagnostics(for: atLimit).count == 1)
        #expect(producer.diagnostics(for: pastLimit).isEmpty)
    }

    @Test("An editor that is not SQL leaves text in another script alone")
    func nonSQLEditorsAreQuiet() {
        let text = "SET greeting \u{4F60}\u{597D}\u{FF0C}\u{4E16}\u{754C}\u{FF01} \u{201C}hi\u{201D}"
        #expect(QueryDiagnosticsFactory.make(for: .redis).diagnostics(for: text).isEmpty)
        #expect(QueryDiagnosticsFactory.make(for: .mysql).diagnostics(for: text).count == 4)
    }

    @Test("The editor checks PostgreSQL with PostgreSQL's quoting")
    func factoryUsesPostgresDialect() {
        let text = "SELECT $$\u{FF1B}$$"
        #expect(QueryDiagnosticsFactory.make(for: .postgresql).diagnostics(for: text).isEmpty)
        #expect(QueryDiagnosticsFactory.make(for: .mysql).diagnostics(for: text).count == 1)
    }

    @Test("The editor treats SQL Server brackets as identifiers")
    func factoryUsesBracketIdentifiers() {
        let text = "SELECT [\u{4EF7}\u{683C}\u{FF08}\u{5143}\u{FF09}] FROM t"
        #expect(QueryDiagnosticsFactory.make(for: .mssql).diagnostics(for: text).isEmpty)
        #expect(QueryDiagnosticsFactory.make(for: .postgresql).diagnostics(for: text).count == 2)
    }

    @Test(
        "The editor treats brackets as identifiers on every SQLite engine",
        arguments: [DatabaseType.sqlite, .libsql, .turso, .cloudflareD1]
    )
    func factoryUsesSQLiteBracketIdentifiers(databaseType: DatabaseType) {
        let text = "SELECT [\u{4EF7}\u{683C}\u{FF08}\u{5143}\u{FF09}] FROM t\u{FF1B}"
        let diagnostics = QueryDiagnosticsFactory.make(for: databaseType).diagnostics(for: text)
        #expect(diagnostics.map(\.range) == [NSRange(location: (text as NSString).length - 1, length: 1)])
    }

    @Test("The editor reads DuckDB brackets as a list, not an identifier")
    func factoryLeavesDuckDBBracketsAsCode() {
        let text = "SELECT [1\u{FF0C} 2]"
        #expect(QueryDiagnosticsFactory.make(for: .duckdb).diagnostics(for: text).map(\.range) == [
            NSRange(location: 9, length: 1)
        ])
    }

    @Test("The editor keeps a string open past a backslash on engines that escape with one", arguments: [
        DatabaseType.clickhouse, .snowflake
    ])
    func factoryUsesEngineBackslashEscapes(databaseType: DatabaseType) {
        let producer = QueryDiagnosticsFactory.make(for: databaseType)

        #expect(producer.diagnostics(for: "SELECT 'a\\'b', '\u{4E2D}\u{6587}\u{FF0C}'").isEmpty)

        let trailing = "SELECT 'it\\'s' FROM t\u{FF1B}"
        #expect(producer.diagnostics(for: trailing).map(\.range) == [
            NSRange(location: (trailing as NSString).length - 1, length: 1)
        ])
    }

    @Test("The editor ends a PostgreSQL string at the quote after a backslash")
    func factoryKeepsPostgresBackslashLiteral() {
        let text = "SELECT 'a\\'b', '\u{4E2D}\u{6587}\u{FF0C}'"
        #expect(QueryDiagnosticsFactory.make(for: .postgresql).diagnostics(for: text).count == 1)
    }
}
