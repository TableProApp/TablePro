//
//  StatementAnchorTests.swift
//  TableProTests
//
//  Finding a statement again after the reader has edited around it, and what a result gets called when the statement
//  is all there is to name it by.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Statement anchor")
@MainActor
struct StatementAnchorTests {

    private func anchor(forStatementAt index: Int, in query: String) throws -> StatementAnchor {
        let statements = SQLStatementScanner.executableStatements(in: query)
        return StatementAnchor(try #require(statements[safeIndex: index]))
    }

    private let script = "SELECT 1;\nUPDATE t SET a = 2;\nDELETE FROM c;"

    // MARK: - Resolving

    @Test("An untouched statement resolves to where it still is")
    func resolvesWhenUnchanged() throws {
        let subject = try anchor(forStatementAt: 1, in: script)
        #expect(subject.resolve(in: script) == subject.range)
    }

    /// The reason the anchor is not a bare offset. Every edit above a statement moves it, and a stored offset would
    /// send the caret into whatever text had taken that place.
    @Test("A statement pushed down by an edit above it is still found")
    func resolvesAfterAnEditAbove() throws {
        let subject = try anchor(forStatementAt: 1, in: script)
        let edited = "-- a note I added later\n\n" + script

        let resolved = try #require(subject.resolve(in: edited))
        #expect((edited as NSString).substring(with: resolved) == "UPDATE t SET a = 2")
        #expect(resolved.location > subject.range.location)
    }

    @Test("A statement that has been edited away resolves to nothing")
    func refusesWhenTheStatementIsGone() throws {
        let subject = try anchor(forStatementAt: 1, in: script)
        #expect(subject.resolve(in: "SELECT 1;\nDELETE FROM c;") == nil)
    }

    @Test("An emptied editor resolves to nothing rather than to the start")
    func refusesOnAnEmptyDocument() throws {
        let subject = try anchor(forStatementAt: 0, in: script)
        #expect(subject.resolve(in: "") == nil)
    }

    /// Two identical statements cannot be told apart, so the nearest one wins. A reader who inserted a line above
    /// expects the statement they ran, not another copy of it further down the script.
    @Test("Among identical statements the nearest one wins")
    func picksTheNearestAmbiguousMatch() throws {
        let query = "SELECT 1;\nSELECT 1;\nSELECT 1;"
        let subject = try anchor(forStatementAt: 2, in: query)

        let edited = "\n" + query
        let resolved = try #require(subject.resolve(in: edited))
        #expect(resolved.location == subject.range.location + 1)
    }

    /// A statement long enough to be truncated in the fingerprint must not match a different statement that merely
    /// starts the same way, which is what the length half of the match is for.
    @Test("A longer statement sharing the same opening does not match")
    func lengthSeparatesSharedPrefixes() throws {
        let long = String(repeating: "a", count: StatementAnchor.previewLimit + 40)
        let query = "SELECT '\(long)' AS a;"
        let subject = try anchor(forStatementAt: 0, in: query)

        #expect(subject.resolve(in: "SELECT '\(long)XYZ' AS a;") == nil)
    }

    // MARK: - Naming

    @Test("A statement names itself when there is no table to name the result after")
    func labelsFromTheStatement() {
        let subject = StatementAnchor(range: NSRange(location: 0, length: 8), preview: "SELECT count(*) FROM t")
        #expect(subject.label == "SELECT count(*) FROM t")
    }

    @Test("A statement written across several lines still reads as one label")
    func labelCollapsesWhitespace() {
        let subject = StatementAnchor(range: NSRange(location: 0, length: 8), preview: "SELECT\n  a,\n  b\nFROM t")
        #expect(subject.label == "SELECT a, b FROM t")
    }

    /// A reader who wrote a comment above a statement has already named it better than its first clause could.
    @Test("A leading comment is the statement's name")
    func labelPrefersALeadingComment() {
        let subject = StatementAnchor(
            range: NSRange(location: 0, length: 8),
            preview: "-- monthly totals\nSELECT count(*) FROM orders"
        )
        #expect(subject.label == "monthly totals")
    }

    @Test("Several comment lines above a statement all become its name")
    func labelJoinsConsecutiveComments() {
        let subject = StatementAnchor(
            range: NSRange(location: 0, length: 8),
            preview: "-- monthly\n-- totals\nSELECT count(*)"
        )
        #expect(subject.label == "monthly totals")
    }

    /// A `--` with nothing after it names nothing, and it must not be left sitting in front of the SQL either.
    @Test("An empty comment falls back to the statement")
    func emptyCommentFallsBack() {
        let subject = StatementAnchor(range: NSRange(location: 0, length: 8), preview: "--\nSELECT 1")
        #expect(subject.label == "SELECT 1")
    }

    @Test("A long label is truncated rather than filling the tab strip")
    func labelIsTruncated() {
        let subject = StatementAnchor(
            range: NSRange(location: 0, length: 8),
            preview: "SELECT a, b, c, d, e, f, g, h, i, j FROM some_table"
        )
        #expect(subject.label.hasSuffix("…"))
        #expect(subject.label.count <= 29)
    }

    // MARK: - What a result is called

    @Test("The table wins when there is one")
    func tableNameWinsOverTheStatement() {
        let subject = StatementAnchor(range: NSRange(location: 0, length: 8), preview: "SELECT * FROM users")
        #expect(ResultSet.label(tableName: "users", anchor: subject, index: 0) == "users")
    }

    @Test("The statement stands in when there is no table")
    func statementNamesTheResult() {
        let subject = StatementAnchor(range: NSRange(location: 0, length: 8), preview: "SELECT count(*)")
        #expect(ResultSet.label(tableName: nil, anchor: subject, index: 0) == "SELECT count(*)")
    }

    @Test("A result with nothing to name it after falls back to its position")
    func counterIsTheLastResort() {
        #expect(ResultSet.label(tableName: nil, anchor: nil, index: 2) == "Result 3")
    }

    @Test("An empty table name is not a name")
    func emptyTableNameIsIgnored() {
        let subject = StatementAnchor(range: NSRange(location: 0, length: 8), preview: "SELECT 1")
        #expect(ResultSet.label(tableName: "", anchor: subject, index: 0) == "SELECT 1")
    }
}

private extension Array {
    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
