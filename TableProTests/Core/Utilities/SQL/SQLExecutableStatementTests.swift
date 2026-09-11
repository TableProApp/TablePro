//
//  SQLExecutableStatementTests.swift
//  TableProTests
//
//  The statements that reach the driver, and the spans that say where each of them came from. The two are produced by
//  one enumeration on purpose, so the guard here is that the text never changes when the span is added.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SQL executable statements")
struct SQLExecutableStatementTests {

    /// Execution used to run through its own filter and the spans through another. The two trim different character
    /// sets and disagree about the terminating semicolon, so repointing execution at the navigation filter would have
    /// changed which text reaches the database. This is the guard that it did not.
    @Test(
        "Adding the span leaves the executed text exactly as it was",
        arguments: [
            "SELECT 1;\nSELECT 2;",
            "SELECT 1",
            "  SELECT 1  ;  ",
            ";;;",
            "",
            "   \n\t  ",
            "SELECT 1;\n-- a comment\n",
            "\u{0B}SELECT 1;\u{0C}",
            "SELECT 1;;SELECT 2;",
            "SELECT ';' AS semi; SELECT 2",
            "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\nEND;\nSELECT 2;",
        ]
    )
    func spansDoNotChangeTheExecutedText(sql: String) {
        #expect(
            SQLStatementScanner.executableStatements(in: sql).map(\.sql)
                == SQLStatementScanner.allStatements(in: sql)
        )
    }

    @Test("Each span covers exactly the text the driver is given")
    func spansCoverTheStatement() {
        let sql = "SELECT 1;\n  UPDATE t SET a = 2;\nDELETE FROM c"
        let statements = SQLStatementScanner.executableStatements(in: sql)
        let text = sql as NSString

        #expect(statements.count == 3)
        for statement in statements {
            #expect(text.substring(with: statement.range) == statement.sql)
        }
    }

    @Test("The span starts at the statement, not at the whitespace it inherited")
    func spanSkipsLeadingTrivia() throws {
        let sql = "SELECT 1;\n\n\nSELECT 2;"
        let second = try #require(SQLStatementScanner.executableStatements(in: sql).last)

        #expect(second.range.location == (sql as NSString).range(of: "SELECT 2").location)
        #expect(second.sql == "SELECT 2")
    }

    /// The semicolon is stripped from the text handed to the driver, so it is outside the span too. A span that
    /// covered it would not round-trip through the substring check above.
    @Test("The terminating semicolon is outside the span")
    func semicolonIsExcluded() throws {
        let only = try #require(SQLStatementScanner.executableStatements(in: "SELECT 1;").first)
        #expect(only.range == NSRange(location: 0, length: 8))
    }

    @Test("Offsetting moves the span without touching the text")
    func offsettingShiftsTheSpan() throws {
        let only = try #require(SQLStatementScanner.executableStatements(in: "SELECT 1").first)
        let shifted = only.offset(by: 10)

        #expect(shifted.range == NSRange(location: 10, length: 8))
        #expect(shifted.sql == only.sql)
    }

    @Test(
        "Invisible characters around a statement are not sent to the driver",
        arguments: [
            "\u{0008}SELECT 1",
            "\u{FEFF}SELECT 1;",
            "\u{200B}\u{00A0}SELECT 1\u{3000};\u{2028}",
            "SELECT 1\u{200E};",
            "\u{E0020}SELECT 1;\u{E0020}",
            "\u{2060}\u{0000}SELECT 1\u{00AD}\u{FFF9};",
        ]
    )
    func invisibleEdgesAreTrimmed(sql: String) {
        #expect(SQLStatementScanner.allStatements(in: sql) == ["SELECT 1"])
    }

    @Test(
        "An invisible character that belongs to the last visible one reaches the driver with it",
        arguments: [
            "SET k \u{2764}\u{FE0F}",
            "SET flag \u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
            "SET k \u{0645}\u{06CC}\u{200C}",
        ]
    )
    func attachedInvisibleCharacterIsSent(sql: String) {
        #expect(SQLStatementScanner.allStatements(in: "\u{FEFF}" + sql + ";\u{0008}") == [sql])
    }

    @Test(
        "A segment of nothing but invisible characters runs nothing",
        arguments: ["\u{0008}", "\u{FEFF};", "\u{00A0}\u{200B}\u{FEFF}\u{0008}\u{3000}", "\u{E0020};\u{2028};"]
    )
    func invisibleOnlySegmentsRunNothing(sql: String) {
        #expect(SQLStatementScanner.executableStatements(in: sql).isEmpty)
    }

    @Test("An invisible segment between two statements is not a statement of its own")
    func invisibleSegmentBetweenStatements() {
        #expect(SQLStatementScanner.allStatements(in: "SELECT 1;\u{0008};SELECT 2") == ["SELECT 1", "SELECT 2"])
    }

    @Test("An invisible character inside a word stays in the text the driver receives")
    func invisibleInsideAWordIsKept() {
        #expect(SQLStatementScanner.allStatements(in: "\u{FEFF}SEL\u{200B}ECT 1") == ["SEL\u{200B}ECT 1"])
    }

    @Test("The span starts at the first visible character after an invisible one")
    func spanSkipsInvisibleLeadingCharacters() throws {
        let sql = "SELECT 1;\n\u{FEFF}\u{0008}SELECT 2;"
        let second = try #require(SQLStatementScanner.executableStatements(in: sql).last)
        let text = sql as NSString

        #expect(second.range.location == text.range(of: "SELECT 2").location)
        #expect(text.substring(with: second.range) == second.sql)
    }

    @Test("Offsets are UTF-16, so text outside the BMP does not shift the span")
    func offsetsAreUTF16() throws {
        let sql = "SELECT '👍';\nSELECT 2;"
        let second = try #require(SQLStatementScanner.executableStatements(in: sql).last)
        #expect((sql as NSString).substring(with: second.range) == "SELECT 2")
    }
}
