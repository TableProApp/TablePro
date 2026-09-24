//
//  BatchStatementRun.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

private let batchLog = Logger(subsystem: "com.TablePro", category: "BatchStatementRun")

/// What a multi-statement run left behind. The results travel out of the lease so the tab, the
/// history and the error sheet are updated after the driver is released.
///
/// A stopped run carries the results of the statements that already ran when the plan cannot take
/// them back, so their rows and their history are kept rather than dropped.
///
/// A unit that answered with a server error rather than throwing one fails the run as
/// ``MultiStatementFailure/batch(sql:)``, and its own output is the last of `results`: a SQL Server
/// batch carries on past most errors, so what it returned is real.
internal enum BatchStatementOutcome<Output> {
    case completed(results: [Output])
    case failed(results: [Output], failure: MultiStatementFailure, errorDescription: String)
    case cancelled(results: [Output])
}

extension BatchStatementOutcome: Sendable where Output: Sendable {}

/// The driver calls one multi-statement run makes, in order, for one ``BatchTransactionPlan``.
///
/// Extracted from the coordinator so the order is testable without a window, a tab or a server:
/// which plan begins a transaction, which commits, and which rolls back after a failure or a Stop
/// are the whole of the behaviour, and every one of them used to be reachable only through the UI.
///
/// Every commit and every rollback goes through ``BatchCommitPoint``, which registers the handle as
/// a protected write and shields the statement from task cancellation. The statements themselves
/// stay cancellable: a Stop between two of them is the one that can still take work back.
@MainActor
internal enum BatchStatementRun {
    internal static func run<Statement: Sendable, Output: Sendable>(
        _ statements: [Statement],
        plan: BatchTransactionPlan,
        mode: PluginTransactionAccessMode,
        driver: DatabaseDriver,
        connectionId: UUID,
        gate: BatchClaimGate,
        failureSQL: (Statement) -> String,
        isCommitPoint: (Statement) -> Bool,
        serverError: (Output) -> String? = { _ in nil },
        execute: @escaping @MainActor @Sendable (Statement) async throws -> Output
    ) async -> BatchStatementOutcome<Output> {
        let opensTransaction = plan.opensTransaction && driver.supportsTransactions
        if opensTransaction {
            do {
                try await driver.beginTransaction(mode: mode)
            } catch {
                return .failed(results: [], failure: .transactionStart, errorDescription: error.localizedDescription)
            }
        }

        var results: [Output] = []
        for statement in statements {
            guard !Task.isCancelled, gate.isCurrent() else {
                await rollback(driver: driver, connectionId: connectionId, plan: plan, opensTransaction: opensTransaction)
                return .cancelled(results: plan.keepsExecutedStatements ? results : [])
            }
            let ran = await runStatement(
                statement,
                isCommitPoint: isCommitPoint(statement),
                driver: driver,
                connectionId: connectionId,
                gate: gate,
                execute: execute
            )
            switch ran {
            case .stopped:
                await rollback(driver: driver, connectionId: connectionId, plan: plan, opensTransaction: opensTransaction)
                return .cancelled(results: plan.keepsExecutedStatements ? results : [])
            case .committed(let result):
                results.append(result)
                if let errorDescription = serverError(result) {
                    await rollback(driver: driver, connectionId: connectionId, plan: plan, opensTransaction: opensTransaction)
                    return .failed(
                        results: results,
                        failure: .batch(sql: failureSQL(statement)),
                        errorDescription: errorDescription
                    )
                }
            case .failed(let failure) where failure.outcomeIsUnknown:
                return .failed(
                    results: results,
                    failure: .commitOutcomeUnknown,
                    errorDescription: failure.errorDescription
                )
            case .failed(let failure):
                await rollback(driver: driver, connectionId: connectionId, plan: plan, opensTransaction: opensTransaction)
                return .failed(
                    results: results,
                    failure: .statement(sql: failureSQL(statement)),
                    errorDescription: failure.errorDescription
                )
            }
        }

        guard opensTransaction else { return .completed(results: results) }
        return await commit(results: results, driver: driver, connectionId: connectionId, gate: gate, plan: plan)
    }

    /// A statement the script wrote itself is ordinary work unless it is the script's own commit,
    /// which is as final as the app's own and goes through the same protection. The batch leaves
    /// the phase again afterwards, so everything after it stays stoppable.
    private static func runStatement<Statement: Sendable, Output: Sendable>(
        _ statement: Statement,
        isCommitPoint: Bool,
        driver: DatabaseDriver,
        connectionId: UUID,
        gate: BatchClaimGate,
        execute: @escaping @MainActor @Sendable (Statement) async throws -> Output
    ) async -> BatchCommitOutcome<Output> {
        guard isCommitPoint else {
            do {
                return .committed(try await execute(statement))
            } catch {
                return .failed(
                    BatchCommitFailure(
                        errorDescription: error.localizedDescription,
                        outcomeIsUnknown: false
                    )
                )
            }
        }
        return await BatchCommitPoint.run(
            driver: driver,
            connectionId: connectionId,
            gate: gate,
            exit: .resumes
        ) { @Sendable in try await execute(statement) }
    }

    /// The app's own commit, and the last thing the run does. The mark it takes is held until the
    /// claim settles rather than released here: between the server's answer and the settle there is
    /// no statement left to stop, and a Stop landing in that gap would drop the results of work the
    /// server has already kept.
    private static func commit<Output>(
        results: [Output],
        driver: DatabaseDriver,
        connectionId: UUID,
        gate: BatchClaimGate,
        plan: BatchTransactionPlan
    ) async -> BatchStatementOutcome<Output> {
        let committed = await BatchCommitPoint.run(
            driver: driver,
            connectionId: connectionId,
            gate: gate,
            exit: .holdsUntilSettled
        ) { @Sendable in try await driver.commitTransaction() }

        switch committed {
        case .stopped:
            await rollback(driver: driver, connectionId: connectionId, plan: plan, opensTransaction: true)
            return .cancelled(results: plan.keepsExecutedStatements ? results : [])
        case .committed:
            return .completed(results: results)
        case .failed(let failure) where failure.outcomeIsUnknown:
            return .failed(results: results, failure: .commitOutcomeUnknown, errorDescription: failure.errorDescription)
        case .failed(let failure):
            await rollback(driver: driver, connectionId: connectionId, plan: plan, opensTransaction: true)
            return .failed(results: results, failure: .commit, errorDescription: failure.errorDescription)
        }
    }

    /// A run in autocommit opened nothing, so it has nothing of its own to take back and a rollback
    /// here could only reach a transaction the user opened before the run started.
    ///
    /// Protected and shielded like a commit, because a Stop is normally what asks for it: measured
    /// in a swiftc probe, a rollback issued inside an already-cancelled task fires the driver's own
    /// cancel handler before the statement is sent, and Dameng never sends it at all.
    ///
    /// A commit whose outcome is unknown never gets here. Nothing on the other end can be asked, so
    /// a rollback there would be a claim rather than an action.
    private static func rollback(
        driver: DatabaseDriver,
        connectionId: UUID,
        plan: BatchTransactionPlan,
        opensTransaction: Bool
    ) async {
        guard plan.rollsBackAfterStop, driver.supportsTransactions else { return }
        let token = DatabaseManager.shared.beginProtectedWrite(on: driver, for: connectionId)
        defer { DatabaseManager.shared.endProtectedWrite(token, for: connectionId) }
        do {
            try await TaskCancellationShield.run { @Sendable in try await driver.rollbackTransaction() }
        } catch {
            guard opensTransaction else {
                batchLog.debug("No open script transaction to roll back: \(error.publicLogShape, privacy: .public)")
                return
            }
            batchLog.error("Rollback failed: \(error.publicLogShape, privacy: .public)")
        }
    }
}
