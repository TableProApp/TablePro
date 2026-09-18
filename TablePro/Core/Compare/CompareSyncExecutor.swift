//
//  CompareSyncExecutor.swift
//  TablePro
//
//  Applies a generated sync script to the target connection.
//  Authorization happens once for the whole run through ExecutionGate, and the
//  statement loop stays inside that call so the task-local receipt remains bound
//  for every statement. Cancellation is cooperative between statements: a driver
//  already blocked in a C call cannot be interrupted.
//

import CryptoKit
import Foundation
import os
import TableProPluginKit

internal enum CompareSyncMode: String, Codable, Hashable, Sendable, CaseIterable {
    case structure
    case data

    internal var displayName: String {
        switch self {
        case .structure: return String(localized: "Structure")
        case .data: return String(localized: "Data")
        }
    }
}

internal struct CompareSyncExecutionSettings {
    internal var errorHandling: ImportErrorHandling = .stopAndRollback
    internal var wrapInTransaction = true
    internal var allowedHazardStatementIds: Set<UUID> = []

    internal func canRun(_ statement: SyncStatement) -> Bool {
        guard statement.isRefusedByDefault else { return true }
        return allowedHazardStatementIds.contains(statement.id)
    }

    /// A structure sync asks a different question from a data sync. Every engine here supports a
    /// transaction over DML, but MySQL, MariaDB and Oracle commit implicitly on every DDL
    /// statement, so wrapping a structure script in one produces a ROLLBACK that undoes nothing
    /// while the run reports "The target is unchanged." `supportsTransactionalDDL` is the flag
    /// that distinguishes them, and the driver already publishes it.
    internal func usesTransaction(for mode: CompareSyncMode, driver: any PluginDatabaseDriver) -> Bool {
        let supported = mode == .structure ? driver.supportsTransactionalDDL : driver.supportsTransactions
        return wrapInTransaction && supported && errorHandling != .skipAndContinue
    }
}

internal struct SyncStatementOutcome: Identifiable {
    internal let id: UUID
    internal let statement: SyncStatement
    internal let error: String?
    internal let wasSkipped: Bool

    /// Whether the driver ran it, which is not the same as whether it was accepted: a statement that
    /// changed more rows than it was built for has already changed them by the time it is refused.
    internal let didExecute: Bool

    internal init(
        id: UUID,
        statement: SyncStatement,
        error: String?,
        wasSkipped: Bool,
        didExecute: Bool = false
    ) {
        self.id = id
        self.statement = statement
        self.error = error
        self.wasSkipped = wasSkipped
        self.didExecute = didExecute
    }

    internal var succeeded: Bool {
        error == nil && !wasSkipped
    }
}

internal struct CompareSyncRunResult {
    internal let outcomes: [SyncStatementOutcome]
    internal let rolledBack: Bool
    internal let cancelled: Bool

    /// Set when the statements ran but the transaction could not be committed, which leaves the
    /// target in whatever state the engine decided rather than in either of the two the user
    /// expects.
    internal let commitFailure: String?

    /// Tables whose storage cannot roll back, so a rolled-back run still left their rows written.
    internal let nonTransactionalObjects: [String]

    internal init(
        outcomes: [SyncStatementOutcome],
        rolledBack: Bool,
        cancelled: Bool,
        commitFailure: String? = nil,
        nonTransactionalObjects: [String] = []
    ) {
        self.outcomes = outcomes
        self.rolledBack = rolledBack
        self.cancelled = cancelled
        self.commitFailure = commitFailure
        self.nonTransactionalObjects = nonTransactionalObjects
    }

    internal var executedCount: Int {
        outcomes.filter { $0.succeeded }.count
    }

    /// Everything the target actually ran, refusals included, which is what says whether the target
    /// was written at all.
    internal var writtenStatementCount: Int {
        outcomes.filter { $0.didExecute }.count
    }

    internal var failedCount: Int {
        outcomes.filter { $0.error != nil }.count
    }

    internal var heldBackCount: Int {
        outcomes.filter { $0.wasSkipped }.count
    }

    internal var rollbackLeftWritesInPlace: Bool {
        rolledBack && !nonTransactionalObjects.isEmpty && writtenStatementCount > 0
    }
}

internal actor CompareSyncExecutor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CompareSyncExecutor")

    private let gate: ExecutionGate

    internal init(gate: ExecutionGate = ExecutionGateProvider.shared) {
        self.gate = gate
    }

    internal func apply(
        statements: [SyncStatement],
        mode: CompareSyncMode,
        settings: CompareSyncExecutionSettings,
        target: DatabaseEndpoint,
        driver: any PluginDatabaseDriver,
        progress: Progress,
        nonTransactionalObjects: Set<String> = []
    ) async throws -> CompareSyncRunResult {
        let runnable = statements.filter { settings.canRun($0) }
        let heldBack = statements.filter { !settings.canRun($0) }

        guard !runnable.isEmpty else {
            return CompareSyncRunResult(
                outcomes: heldBack.map { SyncStatementOutcome(id: $0.id, statement: $0, error: nil, wasSkipped: true) },
                rolledBack: false,
                cancelled: false
            )
        }

        let request = OperationRequest(
            connectionId: target.connectionId,
            databaseType: target.databaseType,
            sql: Self.digest(of: runnable),
            kind: Self.kind(for: mode, statements: runnable, databaseType: target.databaseType),
            caller: .userInterface,
            capabilities: [.mayWrite, .mayRunDestructive, .mayRunMultiStatement, .confirmationPreCleared],
            operationDescription: String(
                format: String(localized: "Apply %@ sync to %@"),
                mode.displayName, target.qualifiedDescription
            )
        )

        progress.totalUnitCount = Int64(runnable.count)
        progress.completedUnitCount = 0
        progress.isCancellable = true

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Applying database sync"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        return try await gate.authorizing(request) {
            try await self.run(
                runnable: runnable,
                heldBack: heldBack,
                mode: mode,
                settings: settings,
                driver: driver,
                dialect: SqlDialect.from(databaseTypeId: target.databaseType.rawValue),
                progress: progress,
                nonTransactionalObjects: nonTransactionalObjects
            )
        }
    }

    /// The script text a statement is shown with ends in `;`, and on Oracle that `;` belongs to some statements and
    /// breaks others: a trigger whose body is a `CALL` is stored INVALID with one. Oracle's statements therefore go out
    /// the way the editor sends them. Every other engine takes the script text as written.
    private static func driverText(of statement: SyncStatement, dialect: SqlDialect) -> String {
        guard dialect == .oracle else { return statement.sql }
        return SQLStatementScanner.executableText(of: statement.sql, dialect: dialect)
    }

    private func run(
        runnable: [SyncStatement],
        heldBack: [SyncStatement],
        mode: CompareSyncMode,
        settings: CompareSyncExecutionSettings,
        driver: any PluginDatabaseDriver,
        dialect: SqlDialect,
        progress: Progress,
        nonTransactionalObjects: Set<String>
    ) async throws -> CompareSyncRunResult {
        let usesTransaction = settings.usesTransaction(for: mode, driver: driver)
        if usesTransaction {
            try await driver.beginTransaction()
        }

        var outcomes = heldBack.map {
            SyncStatementOutcome(id: $0.id, statement: $0, error: nil, wasSkipped: true)
        }
        var openScopes: [(scope: String, closingSQL: String)] = []
        var completed: Int64 = 0
        var stopped = false
        var cancelled = false

        for statement in runnable {
            if progress.isCancelled || Task.isCancelled {
                cancelled = true
                break
            }
            var didExecute = false
            do {
                let result = try await driver.execute(query: Self.driverText(of: statement, dialect: dialect))
                didExecute = true
                try Self.verify(statement, rowsAffected: result.rowsAffected)
                /// A scope is only closed once its closing statement has actually run. Dropping it
                /// before the call left a failed close with nothing to retry it, and the connection
                /// went back to the pool still holding the session state.
                switch statement.sessionEffect {
                case .opens(let scope, let closingSQL):
                    openScopes.append((scope, closingSQL))
                case .closes(let scope):
                    openScopes.removeAll { $0.scope == scope }
                case nil:
                    break
                }
                outcomes.append(SyncStatementOutcome(
                    id: statement.id, statement: statement, error: nil, wasSkipped: false, didExecute: true
                ))
            } catch {
                Self.logger.error("Sync statement failed: \(error.publicLogShape, privacy: .public)")
                outcomes.append(SyncStatementOutcome(
                    id: statement.id, statement: statement,
                    error: error.localizedDescription, wasSkipped: false, didExecute: didExecute
                ))
                if settings.errorHandling != .skipAndContinue {
                    stopped = true
                    break
                }
            }
            completed += 1
            if completed % Self.progressBatchSize == 0 || completed == Int64(runnable.count) {
                progress.completedUnitCount = completed
            }
        }
        progress.completedUnitCount = completed

        await closeSessionScopes(openScopes, on: driver)

        let shouldRollback = usesTransaction
            && (cancelled || (stopped && settings.errorHandling == .stopAndRollback))
        var commitFailure: String?
        if usesTransaction {
            if shouldRollback {
                try? await driver.rollbackTransaction()
            } else {
                /// A commit that throws used to propagate past the whole run, so the result was
                /// discarded and the user got an error with no record of which statements had
                /// already executed. The failure belongs in the result, not instead of it.
                do {
                    try await driver.commitTransaction()
                } catch {
                    Self.logger.error("Sync commit failed: \(error.publicLogShape, privacy: .public)")
                    commitFailure = error.localizedDescription
                }
            }
        }

        /// Named from what ran, not from what the script mentioned: a table whose statements never
        /// reached the target has nothing left in it to warn about.
        let written = Set(outcomes.filter { $0.didExecute }.map { $0.statement.objectName })
        return CompareSyncRunResult(
            outcomes: outcomes,
            rolledBack: shouldRollback,
            cancelled: cancelled,
            commitFailure: commitFailure,
            nonTransactionalObjects: nonTransactionalObjects.intersection(written).sorted()
        )
    }

    /// Session state such as SQL Server's `IDENTITY_INSERT` is not transactional and outlives the
    /// run on a pooled connection, so a scope a stopped run opened is closed whatever stopped it.
    private func closeSessionScopes(
        _ scopes: [(scope: String, closingSQL: String)],
        on driver: any PluginDatabaseDriver
    ) async {
        for scope in scopes.reversed() {
            do {
                _ = try await driver.execute(query: scope.closingSQL)
            } catch {
                Self.logger.error("Closing a sync session scope failed: \(error.publicLogShape, privacy: .public)")
            }
        }
    }

    private static func verify(_ statement: SyncStatement, rowsAffected: Int) throws {
        guard let expected = statement.expectedRowCount,
              KeyedWriteVerification.exceedsExpectation(rowsAffected: rowsAffected, expected: expected) else { return }
        throw CompareSyncError.unsupportedOperation(
            String(
                format: String(localized: "This statement changed %1$d rows where at most %2$d was expected."),
                rowsAffected, expected
            )
        )
    }

    private static let progressBatchSize: Int64 = 25

    private static func kind(
        for mode: CompareSyncMode,
        statements: [SyncStatement],
        databaseType: DatabaseType
    ) -> OperationKind {
        guard mode == .data else { return .schemaMutation }
        return OperationKind.worst(of: statements.map { $0.sql }, databaseType: databaseType)
    }

    /// The confirmation shows the start of the script, and the trailer names the whole of it: the
    /// statement count and a hash of every statement, so two scripts that share their first ten
    /// thousand characters are never recorded as the same run.
    static func digest(of statements: [SyncStatement]) -> String {
        var digest = ""
        var length = 0
        for statement in statements {
            guard length < Self.digestCharacterLimit else { break }
            digest += statement.sql + "\n"
            length += (statement.sql as NSString).length + 1
        }
        let script = statements.map(\.sql).joined(separator: "\n")
        let hash = SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
        digest += "-- \(statements.count) statements, SHA-256 \(hash)\n"
        return digest
    }

    private static let digestCharacterLimit = 10_000
}
