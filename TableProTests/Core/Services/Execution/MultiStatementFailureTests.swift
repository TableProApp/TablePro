//
//  MultiStatementFailureTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Multi-statement failure report")
struct MultiStatementFailureTests {
    private static let syntaxError = "You have an error in your SQL syntax near 'READ WRITE'"

    private static func report(
        _ failure: MultiStatementFailure,
        executed: Int,
        total: Int,
        error: String,
        plan: BatchTransactionPlan = .appTransaction,
        sessionState: PluginSessionTransactionState = .idle,
        unit: MultiStatementUnit = .statement
    ) -> MultiStatementFailureReport {
        MultiStatementFailureContext(
            failure: failure,
            errorDescription: error,
            executedCount: executed,
            totalCount: total,
            plan: plan,
            sessionState: sessionState,
            unit: unit
        ).report()
    }

    @Test("A transaction that failed to start blames no statement and names the start")
    func transactionStartBlamesNoStatement() {
        let report = Self.report(.transactionStart, executed: 0, total: 3, error: Self.syntaxError)
        #expect(report.message == "The transaction could not be started: \(Self.syntaxError)")
        #expect(!report.message.localizedCaseInsensitiveContains("commit"))
        #expect(report.failedStatementIndex == nil)
        #expect(report.failedSQL == nil)
        #expect(report.resultLabel == "Error")
    }

    @Test("A connection that could not be leased reports its own error and blames no statement")
    func connectionBlamesNoStatement() {
        let report = Self.report(.connection, executed: 0, total: 2, error: "Not connected to database")
        #expect(report.message == "Not connected to database")
        #expect(report.failedStatementIndex == nil)
        #expect(report.failedSQL == nil)
    }

    @Test("A failed statement is numbered from one and carries its SQL")
    func statementFailureIsNumbered() {
        let report = Self.report(
            .statement(sql: "INSERT INTO missing VALUES (1)"),
            executed: 2,
            total: 4,
            error: "no such table: missing"
        )
        #expect(report.message == "Statement 3/4 failed: no such table: missing")
        #expect(report.resultLabel == "Error 3")
        #expect(report.failedStatementIndex == 2)
        #expect(report.failedSQL == "INSERT INTO missing VALUES (1)")
    }

    @Test("A commit failure blames no statement after every statement ran")
    func commitBlamesNoStatement() {
        let report = Self.report(.commit, executed: 3, total: 3, error: "deadlock")
        #expect(report.message == "The transaction could not be committed: deadlock")
        #expect(report.failedStatementIndex == nil)
        #expect(report.failedSQL == nil)
    }

    @Test("A failure under a plan that rolled nothing back says the earlier statements stay applied")
    func autocommitFailureNamesWhatStaysApplied() {
        let report = Self.report(
            .statement(sql: "VACUUM"),
            executed: 2,
            total: 4,
            error: "database is locked",
            plan: .autocommit
        )
        #expect(report.message == "Statement 3/4 failed: database is locked The 2 statements before it stay applied.")
        #expect(report.failedStatementIndex == 2)
    }

    @Test("One statement before the failure is named in the singular")
    func oneAppliedStatementReadsAsOne() {
        let report = Self.report(
            .statement(sql: "VACUUM"),
            executed: 1,
            total: 3,
            error: "database is locked",
            plan: .autocommit
        )
        #expect(report.message == "Statement 2/3 failed: database is locked The statement before it stays applied.")
    }

    @Test("Nothing is said about earlier statements when there are none, or when they were rolled back")
    func nothingIsSaidWhenThereIsNothingToSay() {
        let firstStatement = Self.report(
            .statement(sql: "VACUUM"),
            executed: 0,
            total: 3,
            error: "database is locked",
            plan: .autocommit
        )
        #expect(firstStatement.message == "Statement 1/3 failed: database is locked")

        for plan in [BatchTransactionPlan.appTransaction, .scriptTransaction] {
            let rolledBack = Self.report(
                .statement(sql: "VACUUM"),
                executed: 2,
                total: 3,
                error: "database is locked",
                plan: plan
            )
            #expect(rolledBack.message == "Statement 3/3 failed: database is locked")
        }
    }

    @Test("A failure inside the user's own transaction says it is still open")
    func joinedFailureNamesTheOpenTransaction() {
        let report = Self.report(
            .statement(sql: "INSERT INTO missing VALUES (1)"),
            executed: 1,
            total: 2,
            error: "no such table: missing",
            plan: .sessionTransaction,
            sessionState: .inTransaction
        )
        #expect(report.message == """
            Statement 2/2 failed: no such table: missing \
            The transaction on this connection is still open. Commit or roll it back.
            """)
    }

    @Test("A failure that aborted the user's transaction says to roll it back, never to commit")
    func abortedTransactionIsNotToldToCommit() {
        let report = Self.report(
            .statement(sql: "INSERT INTO t VALUES (1)"),
            executed: 1,
            total: 2,
            error: "duplicate key value violates unique constraint",
            plan: .sessionTransaction,
            sessionState: .abortedTransaction
        )
        #expect(report.message.contains("can no longer be committed. Roll it back."))
        #expect(!report.message.localizedCaseInsensitiveContains("Commit or roll"))
    }

    @Test("A session holding only table locks committed each statement as it ran")
    func lockedSessionReadsAsApplied() {
        let report = Self.report(
            .statement(sql: "INSERT INTO t VALUES (1)"),
            executed: 2,
            total: 3,
            error: "Lock wait timeout exceeded",
            plan: .sessionTransaction,
            sessionState: .holdsSessionLocks
        )
        #expect(report.message == """
            Statement 3/3 failed: Lock wait timeout exceeded The 2 statements before it stay applied.
            """)
    }

    /// A transaction that ended during the run either committed the earlier statements or took them
    /// back, and nothing the driver can be asked afterwards says which.
    @Test("A joined run says nothing when the session no longer holds what it held")
    func joinedRunStaysSilentWhenTheStateMoved() {
        for state in [PluginSessionTransactionState.idle, .unknown] {
            let report = Self.report(
                .statement(sql: "INSERT INTO t VALUES (1)"),
                executed: 2,
                total: 3,
                error: "database is locked",
                plan: .sessionTransaction,
                sessionState: state
            )
            #expect(report.message == "Statement 3/3 failed: database is locked")
        }
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
        #expect(MultiStatementFailure.commitOutcomeUnknown.ranStatementCount(executedCount: 3, totalCount: 3) == 3)
    }

    /// A commit whose connection died is not a rollback and must never read as one. Measured on
    /// MySQL 8.4.11, the same commit committed its row once the lock blocking it was released.
    @Test("A commit whose connection died says the outcome is unknown, and never claims a rollback")
    func unknownCommitOutcomeClaimsNothing() {
        let report = Self.report(
            .commitOutcomeUnknown,
            executed: 3,
            total: 3,
            error: "Lost connection to MySQL server during query"
        )
        #expect(report.message.contains("The connection was lost while committing"))
        #expect(report.message.contains("Lost connection to MySQL server during query"))
        #expect(report.message.contains("may or may not be saved"))
        #expect(report.message.localizedCaseInsensitiveContains("rolled back") == false)
        #expect(report.message.localizedCaseInsensitiveContains("could not be committed") == false)
        #expect(report.failedStatementIndex == nil)
        #expect(report.failedSQL == nil)
        #expect(report.resultLabel == "Error")
    }

    /// A commit the server refused is an answer, and the plan's rollback followed it, so that one
    /// still reads as a failed commit rather than as an open question.
    @Test("A commit the server refused still reports a failed commit")
    func refusedCommitStillReportsAFailedCommit() {
        let report = Self.report(.commit, executed: 3, total: 3, error: "deadlock detected")
        #expect(report.message == "The transaction could not be committed: deadlock detected")
        #expect(report.message.contains("may or may not") == false)
    }

    /// The wording is the same whichever plan produced it: the app's own commit under
    /// `.appTransaction` and a script's own commit under `.scriptTransaction` are both unanswered.
    @Test(
        "The unknown-outcome wording does not change with the plan",
        arguments: [BatchTransactionPlan.appTransaction, .scriptTransaction, .sessionTransaction, .autocommit]
    )
    func unknownCommitOutcomeReadsTheSameUnderEveryPlan(plan: BatchTransactionPlan) {
        let report = Self.report(
            .commitOutcomeUnknown,
            executed: 2,
            total: 2,
            error: "MySQL server has gone away",
            plan: plan
        )
        #expect(report.message.contains("may or may not be saved"))
    }

    // MARK: - Batches

    /// A batch that answered with a server error ran, so it is already counted among the executed: its position is the
    /// executed count, not one past it.
    @Test("A batch that answered with an error is numbered from its own output")
    func batchErrorIsNumberedFromItsOutput() {
        let report = Self.report(
            .batch(sql: "SELECT * FROM missing"),
            executed: 2,
            total: 3,
            error: "Line 7: Invalid object name 'missing'.",
            plan: .autocommit,
            unit: .batch
        )
        #expect(report.message.hasPrefix("Batch 2/3 failed: Line 7: Invalid object name 'missing'."))
        #expect(report.resultLabel == "Error 2")
        #expect(report.failedStatementIndex == 1)
        #expect(report.failedSQL == "SELECT * FROM missing")
    }

    @Test("A lone batch reports its error without a position")
    func loneBatchNeedsNoPosition() {
        let report = Self.report(
            .batch(sql: "SELECT 1/0"),
            executed: 1,
            total: 1,
            error: "Line 1: Divide by zero error encountered.",
            plan: .autocommit,
            unit: .batch
        )
        #expect(report.message.hasPrefix("Line 1: Divide by zero error encountered."))
        #expect(!report.message.contains("Batch 1/1"))
        #expect(report.failedStatementIndex == 0)
    }

    /// The server carries on past most errors inside a batch, so what the note can promise is only what is certain.
    @Test("An autocommit batch failure says what ran stays applied, batch by batch")
    func autocommitBatchFailureNotesWhatStays() {
        let first = Self.report(
            .batch(sql: "x"), executed: 1, total: 2, error: "boom", plan: .autocommit, unit: .batch
        )
        #expect(first.message.hasSuffix("Any statement in the batch that ran stays applied."))
        #expect(!first.message.contains("before it"))

        let third = Self.report(
            .batch(sql: "x"), executed: 3, total: 3, error: "boom", plan: .autocommit, unit: .batch
        )
        #expect(third.message.contains("The 2 batches before it stay applied."))
    }

    /// A script that opened its own transaction and failed before committing leaves it open, and a note saying the
    /// work stays applied would be wrong: it is pending in that transaction.
    @Test("A batch failure over an open transaction says the transaction is open instead")
    func batchFailureReportsOpenTransaction() {
        let report = Self.report(
            .batch(sql: "BEGIN TRAN; INSERT INTO t VALUES (1); INSERT INTO t VALUES (1)"),
            executed: 1,
            total: 1,
            error: "Line 1: Violation of PRIMARY KEY constraint.",
            plan: .autocommit,
            sessionState: .inTransaction,
            unit: .batch
        )
        #expect(report.message.contains("still open"))
        #expect(!report.message.contains("stays applied"))
    }

    /// Work done inside a transaction the user already had open is pending in it, or went with it when the error
    /// ended it, and the session cannot say which, so the note claims neither.
    @Test("A batch failure inside the user's own transaction never says the work stays applied")
    func batchFailureInsideUserTransactionClaimsNothing() {
        let ended = Self.report(
            .batch(sql: "UPDATE t SET a = 1"),
            executed: 1,
            total: 1,
            error: "Line 1: The transaction ended in the trigger.",
            plan: .sessionTransaction,
            sessionState: .idle,
            unit: .batch
        )
        #expect(!ended.message.contains("stays applied"))

        let stillOpen = Self.report(
            .batch(sql: "UPDATE t SET a = 1"),
            executed: 1,
            total: 1,
            error: "Line 1: boom",
            plan: .sessionTransaction,
            sessionState: .inTransaction,
            unit: .batch
        )
        #expect(stillOpen.message.contains("still open"))
    }

    @Test("A batch that threw rather than answered is numbered one past the batches that ran")
    func thrownBatchIsNumberedOnePastTheExecuted() {
        let report = Self.report(
            .statement(sql: "SELECT 2"),
            executed: 1,
            total: 3,
            error: "Connection lost",
            plan: .autocommit,
            unit: .batch
        )
        #expect(report.message.hasPrefix("Batch 2/3 failed: Connection lost"))
        #expect(report.failedStatementIndex == 1)
    }

    @Test("Every statement of a failed batch counts as having run")
    func failedBatchCountsAsRun() {
        #expect(MultiStatementFailure.batch(sql: "x").ranStatementCount(executedCount: 2, totalCount: 3) == 2)
        #expect(MultiStatementFailure.statement(sql: "x").ranStatementCount(executedCount: 2, totalCount: 3) == 3)
    }
}
