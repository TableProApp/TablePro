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
    /// A batch that ran and answered with a server error. The server carries on past most errors
    /// inside a batch, so the batch ran, and its own output is part of the run's results.
    case batch(sql: String)
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
        case .batch, .commit, .commitOutcomeUnknown:
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
    var unit: MultiStatementUnit = .statement

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
            return unitReport(sql: sql, position: min(executedCount + 1, totalCount))
        case .batch(let sql):
            return unitReport(sql: sql, position: executedCount)
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

    private func unitReport(sql: String, position: Int) -> MultiStatementFailureReport {
        let failed = failureLine(position: position)
        let note = standingWorkNote(position: position)
        return MultiStatementFailureReport(
            message: note.map { "\(failed) \($0)" } ?? failed,
            resultLabel: String(format: String(localized: "Error %d"), position),
            failedStatementIndex: position > 0 && position <= totalCount ? position - 1 : nil,
            failedSQL: sql
        )
    }

    /// A lone batch is the whole script, so its error needs no position. A statement always has one, because a
    /// single statement never reaches this path.
    private func failureLine(position: Int) -> String {
        switch unit {
        case .statement:
            return String(
                format: String(localized: "Statement %1$d/%2$d failed: %3$@"),
                position, totalCount, errorDescription
            )
        case .batch:
            guard totalCount > 1 else { return errorDescription }
            return String(
                format: String(localized: "Batch %1$d/%2$d failed: %3$@"),
                position, totalCount, errorDescription
            )
        }
    }

    /// What became of the statements that ran before the failure.
    private func standingWorkNote(position: Int) -> String? {
        switch plan {
        case .appTransaction, .scriptTransaction:
            return nil
        case .autocommit:
            return appliedWorkNote(position: position)
        case .sessionTransaction:
            return sessionWorkNote(position: position)
        }
    }

    /// A session holding a lock rather than a transaction committed each statement as it ran,
    /// exactly as autocommit does, so it reads the same way.
    ///
    /// Anything else says nothing. A transaction that ended during the run either committed the
    /// statements before the failure or took them back, and nothing the driver can be asked
    /// afterwards says which.
    private func sessionWorkNote(position: Int) -> String? {
        if let notice = sessionState.openTransactionNotice { return notice }
        guard sessionState == .holdsSessionLocks else { return nil }
        return appliedWorkNote(position: position)
    }

    private func appliedWorkNote(position: Int) -> String? {
        switch unit {
        case .statement:
            return appliedStatementsNote()
        case .batch:
            return sessionState.openTransactionNotice ?? appliedBatchesNote(position: position)
        }
    }

    /// The server carries on past most errors inside a batch and stops at others, and it does not say which
    /// statements it reached, so the failed batch is described by what is certain: whatever of it ran is kept.
    private func appliedBatchesNote(position: Int) -> String {
        let withinBatch = String(localized: "Any statement in the batch that ran stays applied.")
        let before = position - 1
        guard before > 0 else { return withinBatch }
        let earlier = before == 1
            ? String(localized: "The batch before it stays applied.")
            : String(format: String(localized: "The %d batches before it stay applied."), before)
        return "\(earlier) \(withinBatch)"
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

/// What one step of a multi-statement run is: a statement sent on its own, or a batch sent whole.
internal enum MultiStatementUnit: Equatable, Sendable {
    case statement
    case batch
}
