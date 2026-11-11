//
//  AgentTransactionGuard.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

// What an agent's statement or script may do to the transaction its session holds, decided inside the lease.
internal struct AgentTransactionGuard: Sendable {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "AgentTransactionGuard")
    internal static let savepointStatement = "SAVEPOINT tablepro_agent"
    internal static let releaseStatement = "RELEASE SAVEPOINT tablepro_agent"
    internal static let rollbackStatement = "ROLLBACK TO SAVEPOINT tablepro_agent"

    let commitMode: ConnectionCommitMode
    let databaseType: DatabaseType
    let grammar: SQLLexicalGrammar
    let connectionId: UUID

    internal enum Protection: Equatable {
        case none
        case savepoint
        case refuse
    }

    // A failed statement inside an open block aborts it on these engines, which takes the user's pending work with it.
    nonisolated internal static func protection(
        family: TransactionEngineFamily,
        sessionState: PluginSessionTransactionState,
        controlsTransaction: Bool
    ) -> Protection {
        guard !controlsTransaction, sessionState == .inTransaction, family.failedStatementAbortsTransaction else {
            return .none
        }
        return family.takesBackAFailedStatement ? .savepoint : .refuse
    }

    // Runs `body`, told whether this call opened the hold, and answers what the reply should say about the transaction.
    nonisolated func running<T>(
        _ statements: [String],
        writes: Bool,
        on driver: DatabaseDriver,
        _ body: (_ openedHold: Bool) async throws -> T
    ) async throws -> (value: T, notice: String?) {
        let controls = ManualCommit.controlsTransaction(statements, databaseType: databaseType, grammar: grammar)
        if commitMode == .manual, controls { throw ManualCommitTransactionControlRefusal() }
        let family = TransactionEngineFamily.of(databaseType)
        let unseen = ManualCommit.mayEndTransactionUnseen(statements, databaseType: databaseType, grammar: grammar)
        let readsState = commitMode == .manual || controls || unseen || family.failedStatementAbortsTransaction
        let startState: PluginSessionTransactionState = readsState ? await driver.heldSessionTransactionState() : .unknown
        // MySQL's START TRANSACTION commits the transaction already open; PostgreSQL's BEGIN warns and joins it.
        if controls, startState.holdsUserTransaction,
           ManualCommit.startsTransaction(statements, databaseType: databaseType, grammar: grammar) {
            throw OpenTransactionRefusal()
        }
        if commitMode == .manual, startState.holdsUserTransaction, unseen {
            throw ManualCommitTransactionControlRefusal()
        }
        // An agent cannot answer the prompt the editor shows before an implicit commit.
        if commitMode == .manual, startState.holdsUserTransaction,
           ManualCommit.commitsHeldTransaction(statements, databaseType: databaseType, grammar: grammar) {
            throw ManualCommitDDLRefusal()
        }
        let protection = Self.protection(family: family, sessionState: startState, controlsTransaction: controls)
        if protection == .refuse { throw AbortingTransactionRefusal() }

        let opened = try await ManualCommit.openIfNeeded(
            on: driver, statements: statements, databaseType: databaseType, grammar: grammar, commitMode: commitMode
        )
        let value: T
        do {
            if protection == .savepoint {
                value = try await savepointed(on: driver) { try await body(opened) }
            } else {
                value = try await body(opened)
            }
        } catch {
            if opened { await ManualCommit.rollBackOpened(on: driver, connectionId: connectionId) }
            throw error
        }
        let pendingMatters = commitMode == .manual && writes
        guard pendingMatters || startState.holdsUserTransaction else { return (value, nil) }
        let endState = await driver.heldSessionTransactionState()
        return (value, Self.notice(startState: startState, endState: endState, pendingMatters: pendingMatters))
    }

    nonisolated internal static func notice(
        startState: PluginSessionTransactionState,
        endState: PluginSessionTransactionState,
        pendingMatters: Bool
    ) -> String? {
        if startState.holdsUserTransaction, endState == .idle { return ManualCommit.transactionEndedNotice }
        return pendingMatters && endState.holdsUserTransaction ? ManualCommit.pendingNotice : nil
    }

    nonisolated private func savepointed<T>(on driver: DatabaseDriver, _ body: () async throws -> T) async throws -> T {
        _ = try await driver.execute(query: Self.savepointStatement)
        let value: T
        do {
            value = try await body()
        } catch {
            await Self.rollBackToSavepoint(on: driver, connectionId: connectionId)
            throw error
        }
        do {
            _ = try await driver.execute(query: Self.releaseStatement)
        } catch {
            Self.logger.warning("Releasing the agent savepoint failed: \(error.publicLogShape, privacy: .public)")
        }
        return value
    }

    @MainActor
    private static func rollBackToSavepoint(on driver: DatabaseDriver, connectionId: UUID) async {
        let token = DatabaseManager.shared.beginProtectedWrite(on: driver, for: connectionId)
        defer { DatabaseManager.shared.endProtectedWrite(token, for: connectionId) }
        do {
            try await TaskCancellationShield.run { @Sendable in
                _ = try await driver.execute(query: Self.rollbackStatement)
            }
        } catch {
            logger.error("Rolling back to the agent savepoint failed: \(error.publicLogShape, privacy: .public)")
        }
    }
}
