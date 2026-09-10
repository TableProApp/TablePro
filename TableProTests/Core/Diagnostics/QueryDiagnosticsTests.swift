//
//  QueryDiagnosticsTests.swift
//  TableProTests
//
//  The property that matters most here is restraint: a half-typed statement must never be
//  flagged. Only problems more typing cannot fix are reported.
//

import Foundation
import Testing

@testable import TablePro

@Suite("Query Diagnostics")
struct QueryDiagnosticsTests {
    private let sql = SQLDiagnosticsProducer()
    private let mql = MongoDiagnosticsProducer()

    // MARK: - Restraint

    @Test("a half-typed SQL statement is not flagged")
    func testPartialSqlIsQuiet() {
        #expect(sql.diagnostics(for: "SELECT * FROM users WHERE (id =").isEmpty)
    }

    @Test("a half-typed MQL statement is not flagged")
    func testPartialMqlIsQuiet() {
        #expect(mql.diagnostics(for: "db.users.find({").isEmpty)
    }

    @Test("an unterminated string is not flagged while typing")
    func testUnterminatedStringIsQuiet() {
        #expect(sql.diagnostics(for: "SELECT * FROM users WHERE name = 'ali").isEmpty)
        #expect(mql.diagnostics(for: "db.users.find({name: \"ali").isEmpty)
    }

    @Test("empty input produces nothing")
    func testEmptyInput() {
        #expect(sql.diagnostics(for: "").isEmpty)
        #expect(mql.diagnostics(for: "   \n  ").isEmpty)
    }

    @Test("valid statements produce nothing")
    func testValidStatements() {
        #expect(sql.diagnostics(for: "SELECT * FROM users WHERE id = 1;").isEmpty)
        #expect(mql.diagnostics(for: "db.users.find({\"a\": 1})").isEmpty)
        #expect(mql.diagnostics(for: "db.orders.aggregate([{\"$match\": {}}]).limit(5)").isEmpty)
    }

    // MARK: - Real problems

    @Test("a closing bracket with no opener is reported")
    func testUnmatchedCloseReported() {
        let results = sql.diagnostics(for: "SELECT * FROM users)")
        #expect(results.count == 1)
        #expect(results.first?.range == NSRange(location: 19, length: 1))
        #expect(results.first?.severity == .error)
    }

    @Test("a mismatched bracket kind is reported")
    func testMismatchedBracketReported() {
        #expect(!mql.diagnostics(for: "db.users.find([})").isEmpty)
    }

    @Test("an unterminated block comment is reported")
    func testUnterminatedCommentReported() {
        let results = sql.diagnostics(for: "SELECT 1 /* open")
        #expect(results.count == 1)
        #expect(results.first?.message == "Unterminated comment")
    }

    @Test("a method name the app does not know is left alone, because the shell is JavaScript")
    func testUnknownMethodIsNotASyntaxError() {
        #expect(mql.diagnostics(for: "db.users.frobnicate({})").isEmpty)
        #expect(mql.diagnostics(for: "db.users.find({}).forEach(function (d) { print(d); })").isEmpty)
    }

    @Test("a query that does not start with db is reported")
    func testNonDbQueryReported() {
        #expect(!mql.diagnostics(for: "SELECT * FROM users").isEmpty)
    }

    // MARK: - Structure is respected

    @Test("brackets inside a string literal do not count")
    func testBracketsInStringIgnored() {
        #expect(sql.diagnostics(for: "SELECT ')' FROM users").isEmpty)
        #expect(mql.diagnostics(for: "db.users.find({\"a\": \"}\"})").isEmpty)
    }

    @Test("brackets inside a SQL comment do not count")
    func testBracketsInCommentIgnored() {
        #expect(sql.diagnostics(for: "SELECT 1 -- )\n").isEmpty)
        #expect(sql.diagnostics(for: "SELECT 1 /* ) */").isEmpty)
    }

    @Test("a SQL line comment does not start on a double slash")
    func testSqlDoesNotTreatDoubleSlashAsComment() {
        #expect(sql.diagnostics(for: "SELECT 1 // )").count == 1)
    }

    @Test("a double slash starts a comment in a MongoDB query")
    func testMqlHasLineComments() {
        #expect(mql.diagnostics(for: "db.users.find({}) // )").isEmpty)
        #expect(mql.diagnostics(for: "db.users.find({}) /* ) */").isEmpty)
    }
}
