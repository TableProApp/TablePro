//
//  CompareSyncExecutorTransactionOwnerTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

// Answers the session's state the way PostgreSQL does: a failed statement inside a transaction aborts it.
private final class SessionStateDriver: PluginDriverStub, @unchecked Sendable {
    var state: PluginSessionTransactionState
    var events: [String] = []
    var failing: Set<String> = []
    var abortsOnFailure = false
    var rollbackError: (any Error)?

    init(state: PluginSessionTransactionState) {
        self.state = state
    }

    var supportsTransactions: Bool { true }
    var supportsTransactionalDDL: Bool { true }

    func sessionTransactionState() async -> PluginSessionTransactionState { state }

    func execute(query: String) async throws -> PluginQueryResult {
        events.append(query)
        if failing.contains(query) {
            if abortsOnFailure, state == .inTransaction { state = .abortedTransaction }
            throw CompareSyncError.unsupportedOperation("duplicate key value violates unique constraint")
        }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 1, executionTime: 0)
    }

    func beginTransaction() async throws {
        events.append("BEGIN")
        state = .inTransaction
    }

    func commitTransaction() async throws {
        events.append("COMMIT")
        state = .idle
    }

    func rollbackTransaction() async throws {
        events.append("ROLLBACK")
        if let rollbackError { throw rollbackError }
        state = .idle
    }
}

private struct RollbackRefused: Error, LocalizedError {
    var errorDescription: String? { "server closed the connection unexpectedly" }
}

struct CompareSyncExecutorTransactionOwnerTests {
    private let target = DatabaseEndpoint(
        scope: DatabaseScope(connectionId: UUID(), database: "app", schema: nil),
        connectionName: "local",
        databaseType: .duckdb,
        safeModeLevel: .silent,
        color: .blue
    )

    private func apply(
        _ sql: [String],
        on driver: SessionStateDriver,
        errorHandling: ImportErrorHandling = .stopAndRollback
    ) async throws -> CompareSyncRunResult {
        var settings = CompareSyncExecutionSettings()
        settings.errorHandling = errorHandling
        return try await CompareSyncExecutor(gate: AlwaysAllowGate()).apply(
            statements: sql.map { SyncStatement(sql: $0, objectName: "t", summary: $0) },
            mode: .data,
            settings: settings,
            target: target,
            driver: driver,
            progress: Progress()
        )
    }

    // MARK: - Who owns the transaction

    // On DuckDB and PGlite the target is the session itself, where the user's BEGIN may still be open.
    @Test
    func aTransactionTheSessionHoldsGetsNoBeginCommitOrRollbackOfTheRun() async throws {
        let driver = SessionStateDriver(state: .inTransaction)

        let result = try await apply(["INSERT A;", "INSERT B;"], on: driver)

        #expect(driver.events == ["INSERT A;", "INSERT B;"])
        #expect(!result.rolledBack)
        #expect(result.joinedSessionTransaction == .inTransaction)
    }

    @Test
    func aFailureInsideTheSessionsTransactionLeavesItsEndingToItsOwner() async throws {
        let driver = SessionStateDriver(state: .inTransaction)
        driver.failing = ["INSERT B;"]
        driver.abortsOnFailure = true

        let result = try await apply(["INSERT A;", "INSERT B;", "INSERT C;"], on: driver)

        #expect(driver.events == ["INSERT A;", "INSERT B;"])
        #expect(!result.rolledBack)
        #expect(result.joinedSessionTransaction == .abortedTransaction)
    }

    @Test
    func anIdleSessionGetsTheRunsOwnTransaction() async throws {
        let driver = SessionStateDriver(state: .idle)

        let result = try await apply(["INSERT A;"], on: driver)

        #expect(driver.events == ["BEGIN", "INSERT A;", "COMMIT"])
        #expect(result.joinedSessionTransaction == nil)
    }

    // MARK: - Stop and keep what ran

    // PostgreSQL answers that COMMIT with ROLLBACK and no error, so the 50 statements the result called kept were gone.
    @Test
    func stopAndKeepWhatRanReportsTheRollbackAnAbortedTransactionEndsIn() async throws {
        let driver = SessionStateDriver(state: .idle)
        driver.failing = ["INSERT B;"]
        driver.abortsOnFailure = true

        let result = try await apply(["INSERT A;", "INSERT B;", "INSERT C;"], on: driver, errorHandling: .stopAndCommit)

        #expect(driver.events == ["BEGIN", "INSERT A;", "INSERT B;", "ROLLBACK"])
        #expect(result.rolledBack)
        #expect(result.commitFailure == nil)
    }

    @Test
    func stopAndKeepWhatRanCommitsWhereAFailureLeavesTheTransactionOpen() async throws {
        let driver = SessionStateDriver(state: .idle)
        driver.failing = ["INSERT B;"]

        let result = try await apply(["INSERT A;", "INSERT B;", "INSERT C;"], on: driver, errorHandling: .stopAndCommit)

        #expect(driver.events == ["BEGIN", "INSERT A;", "INSERT B;", "COMMIT"])
        #expect(!result.rolledBack)
    }

    @Test
    func aRollbackThatFailsIsReportedRatherThanCountedAsDone() async throws {
        let driver = SessionStateDriver(state: .idle)
        driver.failing = ["INSERT B;"]
        driver.rollbackError = RollbackRefused()

        let result = try await apply(["INSERT A;", "INSERT B;"], on: driver)

        #expect(driver.events.last == "ROLLBACK")
        #expect(!result.rolledBack)
        #expect(result.rollbackFailure == "server closed the connection unexpectedly")
    }
}

@MainActor
struct CompareSyncRunReportTests {
    private let target = DatabaseEndpoint(
        scope: DatabaseScope(connectionId: UUID(), database: "app", schema: nil),
        connectionName: "local",
        databaseType: .duckdb,
        safeModeLevel: .silent,
        color: .blue
    )

    private func failedRun(joined: PluginSessionTransactionState?, rollbackFailure: String? = nil) -> CompareSyncRunResult {
        let ran = SyncStatement(sql: "INSERT A;", objectName: "t", summary: "A")
        let failed = SyncStatement(sql: "INSERT B;", objectName: "t", summary: "B")
        return CompareSyncRunResult(
            outcomes: [
                SyncStatementOutcome(id: ran.id, statement: ran, error: nil, wasSkipped: false, didExecute: true),
                SyncStatementOutcome(id: failed.id, statement: failed, error: "duplicate key", wasSkipped: false)
            ],
            rolledBack: false,
            cancelled: false,
            rollbackFailure: rollbackFailure,
            joinedSessionTransaction: joined
        )
    }

    @Test
    func aRunThatJoinedAnAbortedTransactionSaysToRollItBackAndClaimsNothingApplied() {
        let session = CompareSyncSession(connectionsProvider: { [] })

        session.reportRunResult(failedRun(joined: .abortedTransaction), target: target)

        #expect(session.informationalMessage?.contains("can no longer be committed") == true)
        #expect(session.errorMessage?.contains("stays applied") == false)
    }

    @Test
    func aRunThatJoinedAnOpenTransactionSaysItIsPending() {
        let session = CompareSyncSession(connectionsProvider: { [] })

        session.reportRunResult(failedRun(joined: .inTransaction), target: target)

        #expect(session.informationalMessage?.contains("Commit it to keep the changes") == true)
    }

    @Test
    func aFailedRollbackIsWhatTheWindowReports() {
        let session = CompareSyncSession(connectionsProvider: { [] })

        session.reportRunResult(failedRun(joined: nil, rollbackFailure: "connection lost"), target: target)

        #expect(session.errorMessage?.contains("could not be rolled back: connection lost") == true)
    }
}
