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

    internal struct Savepoint: Equatable, Sendable {
        let open: String
        let release: String?
        let rollback: String

        static let standard = Savepoint(open: savepointStatement, release: releaseStatement, rollback: rollbackStatement)

        // SQL Server and Oracle have no RELEASE; a savepoint lasts until the transaction ends.
        nonisolated static func of(_ family: TransactionEngineFamily) -> Savepoint? {
            switch family {
            case .postgres, .cockroach, .mysql, .sqlite:
                return .standard
            case .sqlServer:
                return Savepoint(
                    open: "SAVE TRANSACTION tablepro_agent", release: nil, rollback: "ROLLBACK TRANSACTION tablepro_agent"
                )
            case .oracle:
                return Savepoint(open: savepointStatement, release: nil, rollback: rollbackStatement)
            // Teradata has no savepoint.
            case .redshift, .duckdb, .redis, .teradata, .other:
                return nil
            }
        }
    }

    // A call of several writes joining the user's open transaction is taken back whole when one fails, so no half
    // of it waits for the user's Commit.
    nonisolated internal static func savepoint(
        family: TransactionEngineFamily,
        protection: Protection,
        sessionState: PluginSessionTransactionState,
        asOneUnit: Bool
    ) -> Savepoint? {
        switch protection {
        case .savepoint:
            return Savepoint.of(family)
        case .refuse:
            return nil
        case .none:
            return asOneUnit && sessionState == .inTransaction ? Savepoint.of(family) : nil
        }
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
        asOneUnit: Bool = false,
        on driver: DatabaseDriver,
        _ body: (_ openedHold: Bool) async throws -> T
    ) async throws -> (value: T, notice: String?) {
        let controls = ManualCommit.controlsTransaction(statements, databaseType: databaseType, grammar: grammar)
        if commitMode == .manual, controls { throw ManualCommitTransactionControlRefusal() }
        let family = TransactionEngineFamily.of(databaseType)
        let unseen = ManualCommit.mayEndTransactionUnseen(statements, databaseType: databaseType, grammar: grammar)
        let readsState = asOneUnit || commitMode == .manual || controls || unseen
            || family.failedStatementAbortsTransaction
        let startState: PluginSessionTransactionState = readsState ? await driver.heldSessionTransactionState() : .unknown
        // MySQL's START TRANSACTION commits the transaction already open; PostgreSQL's BEGIN warns and joins it.
        if controls, startState.holdsUserTransaction,
           ManualCommit.startsTransaction(statements, databaseType: databaseType, grammar: grammar) {
            throw OpenTransactionRefusal()
        }
        // On an idle session the statement's own COMMIT would end the hold this call opens for its write.
        if commitMode == .manual, unseen, writes || startState.holdsUserTransaction {
            throw ManualCommitTransactionControlRefusal()
        }
        let protection = Self.protection(family: family, sessionState: startState, controlsTransaction: controls)
        if protection == .refuse { throw AbortingTransactionRefusal() }

        let savepoint = Self.savepoint(
            family: family, protection: protection, sessionState: startState, asOneUnit: asOneUnit
        )

        let opened = try await ManualCommit.openIfNeeded(
            on: driver, statements: statements, databaseType: databaseType, grammar: grammar, commitMode: commitMode
        )
        let value: T
        do {
            if let savepoint {
                value = try await savepointed(savepoint, on: driver) { try await body(opened) }
            } else {
                value = try await body(opened)
            }
        } catch {
            if opened { await ManualCommit.rollBackOpened(on: driver, connectionId: connectionId) }
            throw error
        }
        let pendingMatters = commitMode == .manual && writes
        // A Teradata ANSI session holds every change in a transaction it opens, which then refuses the next statement.
        let mayHoldWrite = writes && !controls && startState == .idle
            && family.failedStatementAbortsTransaction && !family.takesBackAFailedStatement
        guard pendingMatters || startState.holdsUserTransaction || mayHoldWrite else { return (value, nil) }
        let endState = await driver.heldSessionTransactionState()
        let notice = Self.notice(
            startState: startState, endState: endState, pendingMatters: pendingMatters, openedHold: opened
        )
        return (value, notice)
    }

    nonisolated internal static func notice(
        startState: PluginSessionTransactionState,
        endState: PluginSessionTransactionState,
        pendingMatters: Bool,
        openedHold: Bool
    ) -> String? {
        if startState.holdsUserTransaction || openedHold, endState == .idle { return ManualCommit.transactionEndedNotice }
        if pendingMatters { return endState.holdsUserTransaction ? ManualCommit.pendingNotice : nil }
        return startState == .idle && !openedHold && endState.holdsUserTransaction ? ManualCommit.statementOpenedNotice : nil
    }

    nonisolated private func savepointed<T>(
        _ savepoint: Savepoint,
        on driver: DatabaseDriver,
        _ body: () async throws -> T
    ) async throws -> T {
        _ = try await driver.execute(query: savepoint.open)
        let value: T
        do {
            value = try await body()
        } catch {
            await Self.rollBack(to: savepoint, on: driver, connectionId: connectionId)
            throw error
        }
        guard let release = savepoint.release else { return value }
        do {
            _ = try await driver.execute(query: release)
        } catch {
            Self.logger.warning("Releasing the agent savepoint failed: \(error.publicLogShape, privacy: .public)")
        }
        return value
    }

    @MainActor
    private static func rollBack(to savepoint: Savepoint, on driver: DatabaseDriver, connectionId: UUID) async {
        let token = DatabaseManager.shared.beginProtectedWrite(on: driver, for: connectionId)
        defer { DatabaseManager.shared.endProtectedWrite(token, for: connectionId) }
        do {
            try await TaskCancellationShield.run { @Sendable in
                _ = try await driver.execute(query: savepoint.rollback)
            }
        } catch {
            logger.error("Rolling back to the agent savepoint failed: \(error.publicLogShape, privacy: .public)")
        }
    }
}
