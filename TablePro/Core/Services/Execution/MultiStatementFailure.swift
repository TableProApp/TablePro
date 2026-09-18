//
//  MultiStatementFailure.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum MultiStatementFailure: Equatable, Sendable {
    case connection
    case transactionStart
    case statement(sql: String)
    case commit
    /// The commit went out and the connection died before the answer came back. Measured on MySQL
    /// 8.4.11: a commit blocked by `FLUSH TABLES WITH READ LOCK` survived `kill -9` of the client
    /// and committed its row once the lock was released. Nothing here can say whether the
    /// transaction took, so nothing here may report a rollback.
    case commitOutcomeUnknown

    func ranStatementCount(executedCount: Int, totalCount: Int) -> Int {
        switch self {
        case .connection, .transactionStart:
            return 0
        case .statement:
            return min(executedCount + 1, totalCount)
        case .commit, .commitOutcomeUnknown:
            return executedCount
        }
    }
}

/// Everything the failure banner is written from.
///
/// The plan is part of it because the same banner has three meanings. Under the app's own
/// transaction the statements before the failure are rolled back; under a plan that opens none they
/// stay applied; and under a run that joined the user's own transaction they are pending in it and
/// the transaction is still theirs to end. The user cannot tell which happened from the error alone.
///
/// `sessionState` is read again after the failure rather than carried from the start of the run,
/// because a failure moves it: measured on PostgreSQL 17.11, the statement that failed leaves the
/// block aborted, where a `COMMIT` answers with the command tag `ROLLBACK` and no error.
internal struct MultiStatementFailureContext: Equatable, Sendable {
    let failure: MultiStatementFailure
    let errorDescription: String
    let executedCount: Int
    let totalCount: Int
    let plan: BatchTransactionPlan
    let sessionState: PluginSessionTransactionState

    func report() -> MultiStatementFailureReport {
        switch failure {
        case .connection:
            return MultiStatementFailureReport(
                message: errorDescription,
                resultLabel: String(localized: "Error"),
                failedStatementIndex: nil,
                failedSQL: nil
            )
        case .transactionStart:
            return MultiStatementFailureReport(
                message: String(format: String(localized: "The transaction could not be started: %@"), errorDescription),
                resultLabel: String(localized: "Error"),
                failedStatementIndex: nil,
                failedSQL: nil
            )
        case .statement(let sql):
            return statementReport(sql: sql)
        case .commit:
            return MultiStatementFailureReport(
                message: String(format: String(localized: "The transaction could not be committed: %@"), errorDescription),
                resultLabel: String(localized: "Error"),
                failedStatementIndex: nil,
                failedSQL: nil
            )
        case .commitOutcomeUnknown:
            return unknownCommitReport()
        }
    }

    /// Worded without a rollback in it. The app sent the commit, the connection went before the
    /// answer, and the server decides on its own: the same kill that rolled a commit back under a
    /// read lock was ignored by a commit waiting on `binlog_group_commit_sync_delay`, which then
    /// committed.
    private func unknownCommitReport() -> MultiStatementFailureReport {
        let lost = String(
            format: String(localized: "The connection was lost while committing: %@"),
            errorDescription
        )
        let unknown = String(localized: "The statements may or may not be saved. Check the table before running them again.")
        return MultiStatementFailureReport(
            message: "\(lost) \(unknown)",
            resultLabel: String(localized: "Error"),
            failedStatementIndex: nil,
            failedSQL: nil
        )
    }

    private func statementReport(sql: String) -> MultiStatementFailureReport {
        let position = min(executedCount + 1, totalCount)
        let failed = String(
            format: String(localized: "Statement %1$d/%2$d failed: %3$@"),
            position, totalCount, errorDescription
        )
        return MultiStatementFailureReport(
            message: standingWorkNote().map { "\(failed) \($0)" } ?? failed,
            resultLabel: String(format: String(localized: "Error %d"), position),
            failedStatementIndex: executedCount < totalCount ? executedCount : nil,
            failedSQL: sql
        )
    }

    /// What became of the statements that ran before the failure.
    private func standingWorkNote() -> String? {
        switch plan {
        case .appTransaction, .scriptTransaction:
            return nil
        case .autocommit:
            return appliedStatementsNote()
        case .sessionTransaction:
            return sessionWorkNote()
        }
    }

    /// A session holding a lock rather than a transaction committed each statement as it ran,
    /// exactly as autocommit does, so it reads the same way.
    ///
    /// Anything else says nothing. A transaction that ended during the run either committed the
    /// statements before the failure or took them back, and nothing the driver can be asked
    /// afterwards says which.
    private func sessionWorkNote() -> String? {
        if let notice = sessionState.openTransactionNotice { return notice }
        guard sessionState == .holdsSessionLocks else { return nil }
        return appliedStatementsNote()
    }

    private func appliedStatementsNote() -> String? {
        guard executedCount > 0 else { return nil }
        guard executedCount > 1 else { return String(localized: "The statement before it stays applied.") }
        return String(format: String(localized: "The %d statements before it stay applied."), executedCount)
    }
}

internal struct MultiStatementFailureReport: Equatable, Sendable {
    let message: String
    let resultLabel: String
    let failedStatementIndex: Int?
    let failedSQL: String?
}
