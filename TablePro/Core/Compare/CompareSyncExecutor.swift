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

    internal init(
        outcomes: [SyncStatementOutcome],
        rolledBack: Bool,
        cancelled: Bool,
        commitFailure: String? = nil
    ) {
        self.outcomes = outcomes
        self.rolledBack = rolledBack
        self.cancelled = cancelled
        self.commitFailure = commitFailure
    }

    internal var executedCount: Int {
        outcomes.filter { $0.succeeded }.count
    }

    internal var failedCount: Int {
        outcomes.filter { $0.error != nil }.count
    }

    internal var heldBackCount: Int {
        outcomes.filter { $0.wasSkipped }.count
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
        target: CompareSyncEndpoint,
        driver: any PluginDatabaseDriver,
        progress: Progress
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
                progress: progress
            )
        }
    }

    private func run(
        runnable: [SyncStatement],
        heldBack: [SyncStatement],
        mode: CompareSyncMode,
        settings: CompareSyncExecutionSettings,
        driver: any PluginDatabaseDriver,
        progress: Progress
    ) async throws -> CompareSyncRunResult {
        let usesTransaction = settings.usesTransaction(for: mode, driver: driver)
        if usesTransaction {
            try await driver.beginTransaction()
        }

        var outcomes = heldBack.map {
            SyncStatementOutcome(id: $0.id, statement: $0, error: nil, wasSkipped: true)
        }
        var completed: Int64 = 0
        var stopped = false
        var cancelled = false

        for statement in runnable {
            if progress.isCancelled || Task.isCancelled {
                cancelled = true
                break
            }
            do {
                _ = try await driver.execute(query: statement.sql)
                outcomes.append(SyncStatementOutcome(
                    id: statement.id, statement: statement, error: nil, wasSkipped: false
                ))
            } catch {
                Self.logger.error("Sync statement failed: \(error.localizedDescription, privacy: .public)")
                outcomes.append(SyncStatementOutcome(
                    id: statement.id, statement: statement,
                    error: error.localizedDescription, wasSkipped: false
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
                    Self.logger.error("Sync commit failed: \(error.localizedDescription, privacy: .public)")
                    commitFailure = error.localizedDescription
                }
            }
        }

        return CompareSyncRunResult(
            outcomes: outcomes,
            rolledBack: shouldRollback,
            cancelled: cancelled,
            commitFailure: commitFailure
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

    private static func digest(of statements: [SyncStatement]) -> String {
        var digest = ""
        var length = 0
        for statement in statements {
            guard length < Self.digestCharacterLimit else { break }
            digest += statement.sql + "\n"
            length += (statement.sql as NSString).length + 1
        }
        return digest
    }

    private static let digestCharacterLimit = 10_000
}
