//
//  SQLStatementNavigationTests.swift
//  TableProTests
//
//  Where the caret lands when a reader steps between statements. The same filter feeds the gutter's run controls and
//  the caret-statement band, so a disagreement here is a control drawn somewhere the caret will not go.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SQL statement navigation")
struct SQLStatementNavigationTests {

    private let threeStatements = "SELECT 1;\nSELECT 2;\nSELECT 3;"

    // MARK: - Stepping forward

    @Test("Next moves to the start of the following statement")
    func nextStepsForward() {
        #expect(SQLStatementScanner.statementStart(after: 0, in: threeStatements) == 10)
        #expect(SQLStatementScanner.statementStart(after: 10, in: threeStatements) == 20)
    }

    @Test("Next from inside a statement reaches the one after it, not its own start")
    func nextFromInsideAStatement() {
        #expect(SQLStatementScanner.statementStart(after: 13, in: threeStatements) == 20)
    }

    @Test("Next stops at the last statement rather than wrapping")
    func nextDoesNotWrap() {
        #expect(SQLStatementScanner.statementStart(after: 20, in: threeStatements) == nil)
        #expect(SQLStatementScanner.statementStart(after: 28, in: threeStatements) == nil)
    }

    // MARK: - Stepping back

    @Test("Previous moves to the start of the preceding statement")
    func previousStepsBack() {
        #expect(SQLStatementScanner.statementStart(before: 20, in: threeStatements) == 10)
        #expect(SQLStatementScanner.statementStart(before: 10, in: threeStatements) == 0)
    }

    /// A reader part-way through a statement expects the first press to take them to its start, the way every
    /// paragraph-wise motion in a text editor behaves, rather than skipping the statement they were reading.
    @Test("Previous from inside a statement lands on that statement's own start")
    func previousFromInsideLandsOnOwnStart() {
        #expect(SQLStatementScanner.statementStart(before: 13, in: threeStatements) == 10)
    }

    @Test("Previous stops at the first statement rather than wrapping")
    func previousDoesNotWrap() {
        #expect(SQLStatementScanner.statementStart(before: 0, in: threeStatements) == nil)
    }

    // MARK: - Selection extension

    /// Selection reaches the far edge of the text rather than the start of the next statement. Reusing the navigation
    /// boundary would leave the last statement's own body impossible to select, because past its start there is no
    /// next statement to reach for.
    @Test("Selecting forward reaches the end of the last statement")
    func selectionReachesTheLastStatementsEnd() {
        #expect(SQLStatementScanner.statementSelectionEnd(after: 0, in: threeStatements) == 10)
        #expect(SQLStatementScanner.statementSelectionEnd(after: 10, in: threeStatements) == 20)
        #expect(SQLStatementScanner.statementSelectionEnd(after: 20, in: threeStatements) == 29)
    }

    @Test("Selecting forward from the document end has nowhere left to go")
    func selectionStopsAtTheEnd() {
        #expect(SQLStatementScanner.statementSelectionEnd(after: 29, in: threeStatements) == nil)
    }

    @Test("A single statement can still be selected whole")
    func singleStatementCanBeSelected() {
        #expect(SQLStatementScanner.statementSelectionEnd(after: 0, in: "SELECT 1;") == 9)
    }

    // MARK: - What is navigable

    @Test("A comment-only segment is not a place the caret is sent")
    func commentsAreSkipped() {
        let sql = "SELECT 1;\n-- just a note\n"
        #expect(SQLStatementScanner.navigableStatements(in: sql).count == 1)
        #expect(SQLStatementScanner.statementStart(after: 0, in: sql) == nil)
    }

    /// A leading comment is part of the statement it precedes, so the caret lands on the comment, which is the same
    /// anchor the gutter draws that statement's run control on.
    @Test("A statement's leading comment is where it starts")
    func leadingCommentIsTheStart() {
        let sql = "SELECT 1;\n-- why\nSELECT 2;"
        #expect(SQLStatementScanner.statementStart(after: 0, in: sql) == 10)
    }

    @Test("Trailing whitespace is not a destination")
    func trailingWhitespaceIsNotADestination() {
        #expect(SQLStatementScanner.statementStart(after: 0, in: "SELECT 1;\n   \n") == nil)
    }

    @Test("An empty document has nowhere to go")
    func emptyDocument() {
        #expect(SQLStatementScanner.statementStart(after: 0, in: "") == nil)
        #expect(SQLStatementScanner.statementStart(before: 0, in: "") == nil)
    }

    @Test("A single statement has no neighbour in either direction")
    func singleStatement() {
        #expect(SQLStatementScanner.statementStart(after: 0, in: "SELECT 1;") == nil)
        #expect(SQLStatementScanner.statementStart(before: 0, in: "SELECT 1;") == nil)
    }

    /// A routine body is one statement, so stepping over it lands past its `END` rather than inside it.
    @Test("A BEGIN ... END body is stepped over as one statement")
    func routineBodyIsOneStop() throws {
        let sql = "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  SELECT 2;\nEND;\nSELECT 3;"
        let destination = try #require(SQLStatementScanner.statementStart(after: 0, in: sql, dialect: .mysql))
        #expect((sql as NSString).substring(from: destination).hasPrefix("SELECT 3"))
    }

    @Test("Navigation and the gutter's controls agree on which statements exist")
    func navigationMatchesTheGutter() {
        let sql = "SELECT 1;\n\n-- note\nUPDATE t SET a = 1;\n   \nDELETE FROM c"
        let navigable = SQLStatementScanner.navigableStatements(in: sql)

        var reached: [Int] = []
        var offset: Int? = SQLStatementScanner.navigableStatements(in: sql).first?.contentRange.location
        while let current = offset {
            reached.append(current)
            offset = SQLStatementScanner.statementStart(after: current, in: sql)
        }

        #expect(reached == navigable.map(\.contentRange.location))
    }

    @Test("Offsets are UTF-16, so text outside the BMP does not shift the destination")
    func offsetsAreUTF16() throws {
        let sql = "SELECT '👍';\nSELECT 2;"
        let destination = try #require(SQLStatementScanner.statementStart(after: 0, in: sql))
        #expect((sql as NSString).substring(from: destination) == "SELECT 2;")
    }
}
