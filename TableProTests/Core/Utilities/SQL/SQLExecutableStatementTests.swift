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

    @Test("Offsets are UTF-16, so text outside the BMP does not shift the span")
    func offsetsAreUTF16() throws {
        let sql = "SELECT '👍';\nSELECT 2;"
        let second = try #require(SQLStatementScanner.executableStatements(in: sql).last)
        #expect((sql as NSString).substring(with: second.range) == "SELECT 2")
    }
}
