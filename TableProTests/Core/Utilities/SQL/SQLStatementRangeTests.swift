//
//  SQLStatementRangeTests.swift
//  TableProTests
//
//  The gutter's run controls and the caret-statement band are both drawn from these ranges, and the same scan decides
//  what actually runs, so a range that disagrees with the text is a control that runs the wrong statement.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SQL statement scanner - located ranges")
struct SQLStatementRangeTests {

    private func substring(_ sql: String, _ range: NSRange) -> String {
        (sql as NSString).substring(with: range)
    }

    @Test("Statements partition the document with no gaps and no overlap")
    func rangesPartitionTheDocument() {
        let sql = "SELECT 1;\nSELECT 2;\nSELECT 3"
        let statements = SQLStatementScanner.locatedStatements(in: sql)

        #expect(statements.count == 3)
        var cursor = 0
        for statement in statements {
            #expect(statement.range.location == cursor)
            cursor = statement.range.upperBound
        }
        #expect(cursor == (sql as NSString).length)
    }

    @Test("contentRange skips the whitespace inherited from the previous statement")
    func contentRangeSkipsInheritedWhitespace() {
        let sql = "SELECT 1;\n\n   SELECT 2;"
        let statements = SQLStatementScanner.locatedStatements(in: sql)

        #expect(statements.count == 2)
        #expect(substring(sql, statements[0].contentRange) == "SELECT 1;")
        #expect(substring(sql, statements[1].contentRange) == "SELECT 2;")
    }

    /// The raw offset is the index just past the previous semicolon, so on a script written one statement per line it
    /// lands on the newline that ended the previous line. A control anchored there would be drawn a line early.
    @Test("contentRange starts a line later than the raw offset")
    func contentRangeMovesOffThePreviousLine() {
        let sql = "SELECT 1;\nSELECT 2;"
        let second = SQLStatementScanner.locatedStatements(in: sql)[1]

        #expect(second.range.location == 9)
        #expect(second.contentRange.location == 10)
    }

    @Test("A leading comment belongs to the statement it precedes")
    func leadingCommentIsPartOfTheStatement() {
        let sql = "SELECT 1;\n-- why\nSELECT 2;"
        let second = SQLStatementScanner.locatedStatements(in: sql)[1]

        #expect(substring(sql, second.contentRange) == "-- why\nSELECT 2;")
    }

    @Test("A trailing whitespace-only segment carries no content")
    func trailingWhitespaceHasNoContent() {
        let sql = "SELECT 1;\n   \n"
        let statements = SQLStatementScanner.locatedStatements(in: sql)

        #expect(statements.count == 2)
        #expect(statements[0].hasContent)
        #expect(!statements[1].hasContent)
        #expect(statements[1].contentRange.length == 0)
    }

    @Test("A comment-only document carries no content")
    func commentOnlyDocument() {
        let statements = SQLStatementScanner.locatedStatements(in: "-- nothing here\n")

        #expect(statements.count == 1)
        #expect(!statements[0].hasContent)
    }

    @Test("An empty document has no statements")
    func emptyDocument() {
        #expect(SQLStatementScanner.locatedStatements(in: "").isEmpty)
    }

    @Test("CRLF line endings do not leak into a content range")
    func crlfLineEndings() {
        let sql = "SELECT 1;\r\nSELECT 2;\r\n"
        let statements = SQLStatementScanner.locatedStatements(in: sql)

        #expect(statements.count == 3)
        #expect(substring(sql, statements[1].contentRange) == "SELECT 2;")
    }

    @Test("Ranges are UTF-16 offsets, so text outside the BMP stays aligned")
    func rangesAreUTF16Offsets() {
        let sql = "SELECT '👍';\nSELECT 2;"
        let statements = SQLStatementScanner.locatedStatements(in: sql)

        #expect(statements.count == 2)
        #expect(substring(sql, statements[0].contentRange) == "SELECT '👍';")
        #expect(substring(sql, statements[1].contentRange) == "SELECT 2;")
    }

    /// The gutter runs `contentRange` and the caret path runs `statementAtCursor`. If those two disagree the control
    /// runs something other than what it is drawn beside.
    @Test("Running a contentRange yields the same SQL the caret path would")
    func contentRangeMatchesTheCaretPath() {
        let sql = "SELECT 1;\n\n-- note\nUPDATE t SET a = 1;\nDELETE FROM c"
        let nsSQL = sql as NSString

        for statement in SQLStatementScanner.locatedStatements(in: sql) where statement.hasContent {
            let fromRange = SQLStatementScanner.allStatements(in: nsSQL.substring(with: statement.contentRange))
            let fromCaret = SQLStatementScanner.statementAtCursor(
                in: sql,
                cursorPosition: statement.contentRange.location
            )
            #expect(fromRange == [fromCaret])
        }
    }
}
