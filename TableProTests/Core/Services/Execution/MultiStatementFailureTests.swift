//
//  MultiStatementFailureTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Multi-statement failure report")
struct MultiStatementFailureTests {
    private static let syntaxError = "You have an error in your SQL syntax near 'READ WRITE'"

    @Test("A transaction that failed to start blames no statement and names the start")
    func transactionStartBlamesNoStatement() {
        let report = MultiStatementFailure.transactionStart.report(
            executedCount: 0,
            totalCount: 3,
            errorDescription: Self.syntaxError
        )
        #expect(report.message == "The transaction could not be started: \(Self.syntaxError)")
        #expect(!report.message.localizedCaseInsensitiveContains("commit"))
        #expect(report.failedStatementIndex == nil)
        #expect(report.failedSQL == nil)
        #expect(report.resultLabel == "Error")
    }

    @Test("A connection that could not be leased reports its own error and blames no statement")
    func connectionBlamesNoStatement() {
        let report = MultiStatementFailure.connection.report(
            executedCount: 0,
            totalCount: 2,
            errorDescription: "Not connected to database"
        )
        #expect(report.message == "Not connected to database")
        #expect(report.failedStatementIndex == nil)
        #expect(report.failedSQL == nil)
    }

    @Test("A failed statement is numbered from one and carries its SQL")
    func statementFailureIsNumbered() {
        let report = MultiStatementFailure.statement(sql: "INSERT INTO missing VALUES (1)").report(
            executedCount: 2,
            totalCount: 4,
            errorDescription: "no such table: missing"
        )
        #expect(report.message == "Statement 3/4 failed: no such table: missing")
        #expect(report.resultLabel == "Error 3")
        #expect(report.failedStatementIndex == 2)
        #expect(report.failedSQL == "INSERT INTO missing VALUES (1)")
    }

    @Test("A commit failure blames no statement after every statement ran")
    func commitBlamesNoStatement() {
        let report = MultiStatementFailure.commit.report(
            executedCount: 3,
            totalCount: 3,
            errorDescription: "deadlock"
        )
        #expect(report.message == "The transaction could not be committed: deadlock")
        #expect(report.failedStatementIndex == nil)
        #expect(report.failedSQL == nil)
    }

    @Test("Nothing ran when the connection or the transaction start failed")
    func nothingRanBeforeTheFirstStatement() {
        #expect(MultiStatementFailure.connection.ranStatementCount(executedCount: 0, totalCount: 3) == 0)
        #expect(MultiStatementFailure.transactionStart.ranStatementCount(executedCount: 0, totalCount: 3) == 0)
    }

    @Test("A failed statement counts as reaching the server, and a commit failure counts every statement")
    func ranStatementsIncludeTheOneThatFailed() {
        #expect(MultiStatementFailure.statement(sql: "x").ranStatementCount(executedCount: 1, totalCount: 3) == 2)
        #expect(MultiStatementFailure.statement(sql: "x").ranStatementCount(executedCount: 2, totalCount: 3) == 3)
        #expect(MultiStatementFailure.commit.ranStatementCount(executedCount: 3, totalCount: 3) == 3)
    }
}
