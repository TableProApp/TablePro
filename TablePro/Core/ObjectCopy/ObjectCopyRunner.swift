//
//  ObjectCopyRunner.swift
//  TablePro
//
//  Runs a plan: the database, then the DDL, then the rows.
//
//  Authorization happens once for the whole copy through `ExecutionGate`, and
//  every statement stays inside that call so the task-local receipt is bound
//  for all of them. Asking twice, once for the DDL and once for the rows, would
//  put two confirmations in front of one action the user already approved.
//
//  Cancellation is cooperative between batches: a driver already blocked in a C
//  call cannot be interrupted, so a cancelled run stops at the next batch
//  boundary and reports what it had already written.
//

import Foundation
import os
import TableProPluginKit

internal struct ObjectCopyObjectOutcome: Identifiable, Sendable {
    internal let selection: ObjectCopySelection
    internal let rowsCopied: Int
    internal let error: String?

    internal var id: String { selection.id }
    internal var succeeded: Bool { error == nil }
}

internal struct ObjectCopyRunResult: Sendable {
    internal let outcomes: [ObjectCopyObjectOutcome]
    internal let rowsCopied: Int
    internal let cancelled: Bool
    internal let createdDatabase: String?

    /// Counted by object rather than by outcome. A table copied with its structure and its rows
    /// produces one outcome for each phase, and reporting "2 objects" for one table is how a
    /// summary comes to overstate what the run did.
    internal var failedCount: Int {
        Set(outcomes.filter { $0.error != nil }.map(\.id)).count
    }

    internal var succeededCount: Int {
        let failed = Set(outcomes.filter { $0.error != nil }.map(\.id))
        return Set(outcomes.filter(\.succeeded).map(\.id)).subtracting(failed).count
    }

    internal var firstError: String? { outcomes.compactMap(\.error).first }
}

@MainActor
internal struct ObjectCopyRunner {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ObjectCopyRunner")

    private let manager: DatabaseManager
    private let gate: ExecutionGate

    internal init(manager: DatabaseManager = .shared, gate: ExecutionGate = ExecutionGateProvider.shared) {
        self.manager = manager
        self.gate = gate
    }

    internal func run(_ plan: ObjectCopyPlan, progress: ObjectCopyProgress) async throws -> ObjectCopyRunResult {
        let request = plan.request
        progress.setTotalRows(plan.estimatedRowTotal)

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Copying database objects"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        return try await gate.authorizing(authorizationRequest(for: plan)) {
            try await self.execute(plan, request: request, progress: progress)
        }
    }

    // MARK: - Phases

    private func execute(
        _ plan: ObjectCopyPlan,
        request: ObjectCopyRequest,
        progress: ObjectCopyProgress
    ) async throws -> ObjectCopyRunResult {
        var createdDatabase: String?
        if case .newDatabase(_, let name, let values) = request.destination {
            try await createDatabase(named: name, values: values, on: request.target.connectionId)
            createdDatabase = name
        }

        var outcomes: [ObjectCopyObjectOutcome] = []
        var cancelled = false
        var rowsCopied = 0

        func finished() -> ObjectCopyRunResult {
            ObjectCopyRunResult(
                outcomes: outcomes,
                rowsCopied: rowsCopied,
                cancelled: cancelled,
                createdDatabase: createdDatabase
            )
        }

        /// Torn down before anything is built, and children first, so a foreign key is gone before
        /// the table it points at and a trigger before the table that owns it. One parent-first
        /// pass had every DROP rejected by the constraint below it.
        ///
        /// Both phases run under one `withMetadataDriver` call and, where the engine has them,
        /// with foreign key checks off and a transaction around them. Split across two calls, a
        /// Stop between them or a failing first CREATE left every later object dropped with
        /// nothing put back.
        if !plan.cleanupGroups.isEmpty || !plan.creationGroups.isEmpty {
            let result = try await runStructure(plan, request: request, progress: progress)
            outcomes += result.outcomes
            cancelled = cancelled || result.cancelled
            if result.stopped { return finished() }
        }

        /// Every table the copy will append to is emptied before any of them is filled, children
        /// first. Clearing each one immediately before its own rows meant the first parent DELETE
        /// met child rows that were still there, and a cascading key took rows out of tables the
        /// user had not selected.
        if !cancelled, !plan.clearGroups.isEmpty {
            let result = try await runDDL(plan.clearGroups, request: request, progress: progress)
            outcomes += result.outcomes.filter { $0.error != nil }
            cancelled = cancelled || result.cancelled
            if result.stopped { return finished() }
        }

        if !cancelled, request.content.includesData {
            let dataOutcomes = await runData(plan, request: request, progress: progress)
            outcomes += dataOutcomes.outcomes
            cancelled = cancelled || dataOutcomes.cancelled
            rowsCopied = dataOutcomes.rowsCopied
            if dataOutcomes.stopped { return finished() }
        }

        /// A trigger fires on the rows the copy writes, so it goes in once they are in. Installed
        /// with the rest of the DDL, duplicating a database with an audit trigger produced a
        /// second audit row for every row copied.
        if !cancelled, !plan.afterDataGroups.isEmpty {
            let result = try await runDDL(plan.afterDataGroups, request: request, progress: progress)
            outcomes += result.outcomes
            cancelled = cancelled || result.cancelled
        }

        return finished()
    }

    private func createDatabase(named name: String, values: [String: String], on connectionId: UUID) async throws {
        let scope = DatabaseScope(connectionId: connectionId, database: "", schema: nil)
        try await manager.withMetadataDriver(scope: scope) { driver in
            try await driver.createDatabase(CreateDatabaseRequest(name: name, values: values))
        }
    }

    // MARK: - Structure

    private struct DDLResult {
        var outcomes: [ObjectCopyObjectOutcome] = []
        var cancelled = false
        /// True when the run must not go on to the rows, because the tables they need are missing.
        var stopped = false
    }

    /// Every drop and every create, in one scoped call, wrapped where the engine allows it.
    ///
    /// A replacement is destructive only in the moment between its DROP and its CREATE, so the two
    /// have to be one unit as far as the engine can make them: a transaction where DDL is
    /// transactional, and otherwise at least one connection lease with foreign key checks off so
    /// the ordering cannot fail half way.
    private func runStructure(
        _ plan: ObjectCopyPlan,
        request: ObjectCopyRequest,
        progress: ObjectCopyProgress
    ) async throws -> DDLResult {
        let groups = plan.cleanupGroups + plan.creationGroups
        let errorHandling = request.errorHandling
        let scope = request.target.scope
        let hasCleanup = !plan.cleanupGroups.isEmpty

        return try await manager.withMetadataDriver(scope: scope) { driver in
            guard let plugin = CompareMetadataService.pluginDriver(from: driver) else {
                throw ObjectCopyError.refused(Self.noTargetDriver)
            }
            let usesTransaction = hasCleanup && plugin.supportsTransactionalDDL
            let relaxesForeignKeys = hasCleanup && !usesTransaction
            if usesTransaction { try await plugin.beginTransaction(mode: .readWrite) }
            if relaxesForeignKeys {
                for statement in plugin.foreignKeyDisableStatements() ?? [] {
                    _ = try? await plugin.execute(query: statement)
                }
            }

            let result = await Self.execute(
                groups, on: plugin, errorHandling: errorHandling, progress: progress
            )

            if relaxesForeignKeys {
                for statement in plugin.foreignKeyEnableStatements() ?? [] {
                    _ = try? await plugin.execute(query: statement)
                }
            }
            if usesTransaction {
                if result.stopped {
                    try? await plugin.rollbackTransaction()
                } else {
                    try await plugin.commitTransaction()
                }
            }
            return result
        }
    }

    nonisolated private static func execute(
        _ groups: [ObjectCopyStatementGroup],
        on driver: any PluginDatabaseDriver,
        errorHandling: ImportErrorHandling,
        progress: ObjectCopyProgress
    ) async -> DDLResult {
        var result = DDLResult()
        for group in groups where !group.statements.isEmpty {
            if progress.isCancelled || Task.isCancelled {
                result.cancelled = true
                result.stopped = true
                break
            }
            progress.startObject(group.selection.qualifiedName)
            do {
                for statement in group.statements {
                    _ = try await driver.execute(query: statement.sql)
                }
                result.outcomes.append(ObjectCopyObjectOutcome(
                    selection: group.selection, rowsCopied: 0, error: nil
                ))
            } catch {
                logger.error(
                    "Copy DDL failed for \(group.selection.qualifiedName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                result.outcomes.append(ObjectCopyObjectOutcome(
                    selection: group.selection, rowsCopied: 0, error: error.localizedDescription
                ))
                guard errorHandling == .skipAndContinue else {
                    result.stopped = true
                    break
                }
            }
        }
        return result
    }

    private func runDDL(
        _ groups: [ObjectCopyStatementGroup],
        request: ObjectCopyRequest,
        progress: ObjectCopyProgress
    ) async throws -> DDLResult {
        let runnable = groups.filter { !$0.statements.isEmpty }
        guard !runnable.isEmpty else { return DDLResult() }

        let errorHandling = request.errorHandling
        return try await manager.withMetadataDriver(scope: request.target.scope) { driver in
            guard let plugin = CompareMetadataService.pluginDriver(from: driver) else {
                throw ObjectCopyError.refused(Self.noTargetDriver)
            }
            return await Self.execute(
                runnable, on: plugin, errorHandling: errorHandling, progress: progress
            )
        }
    }

    // MARK: - Data

    private struct DataResult {
        var outcomes: [ObjectCopyObjectOutcome] = []
        var cancelled = false
        var stopped = false
        /// Only what was committed. A cancelled table rolls its rows back, so counting what the
        /// copier inserted reported rows the target never kept.
        var rowsCopied = 0
    }

    /// Each table is its own unit of work, so one that fails leaves the ones already copied alone.
    /// Both scopes are open at once, which the planner has already established is safe: two scopes
    /// on one connection are refused unless both route to the pool.
    private func runData(
        _ plan: ObjectCopyPlan,
        request: ObjectCopyRequest,
        progress: ObjectCopyProgress
    ) async -> DataResult {
        var result = DataResult()
        let targetType = request.target.databaseType

        for step in plan.dataSteps {
            if progress.isCancelled || Task.isCancelled {
                result.cancelled = true
                result.stopped = true
                break
            }
            progress.startObject(step.qualifiedTargetName)
            let wrapsInTransaction = request.wrapEachTableInTransaction
                && request.errorHandling != .skipAndContinue

            do {
                let outcome = try await copyRows(
                    step,
                    request: request,
                    targetType: targetType,
                    wrapsInTransaction: wrapsInTransaction,
                    completedBefore: result.rowsCopied,
                    progress: progress
                )
                /// A cancelled table that rolled back neither counts as copied nor reads as an
                /// object that succeeded. On a target without transactions nothing rolled back, so
                /// the batches already flushed are in the target and saying otherwise hides them
                /// from a user about to retry and double the rows.
                guard !outcome.cancelled else {
                    result.cancelled = true
                    result.stopped = true
                    if outcome.committed > 0 {
                        result.rowsCopied += outcome.committed
                        result.outcomes.append(ObjectCopyObjectOutcome(
                            selection: step.selection, rowsCopied: outcome.committed, error: nil
                        ))
                    }
                    progress.setRowsForCurrentObject(0, completedBefore: result.rowsCopied)
                    break
                }
                result.rowsCopied += outcome.inserted
                result.outcomes.append(ObjectCopyObjectOutcome(
                    selection: step.selection, rowsCopied: outcome.inserted, error: nil
                ))
            } catch is CancellationError {
                /// Stop reaching the driver mid-stream is the user stopping, not the copy failing,
                /// and the two produce different notifications.
                result.cancelled = true
                result.stopped = true
                progress.setRowsForCurrentObject(0, completedBefore: result.rowsCopied)
                break
            } catch {
                Self.logger.error(
                    "Copy rows failed for \(step.qualifiedTargetName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                result.outcomes.append(ObjectCopyObjectOutcome(
                    selection: step.selection, rowsCopied: 0, error: error.localizedDescription
                ))
                guard request.errorHandling == .skipAndContinue else {
                    result.stopped = true
                    break
                }
            }
        }
        return result
    }

    private func copyRows(
        _ step: ObjectCopyTableStep,
        request: ObjectCopyRequest,
        targetType: DatabaseType,
        wrapsInTransaction: Bool,
        completedBefore: Int,
        progress: ObjectCopyProgress
    ) async throws -> ObjectCopyRowCopier.Outcome {
        let sourceScope = request.source.scope
        let targetScope = request.target.scope
        let copier = ObjectCopyRowCopier(step: step, targetDatabaseType: targetType)
        let errorHandling = request.errorHandling

        /// The injected manager on both sides. Reaching for the singleton on the target bypassed
        /// the caller's own connections and routing, which is the whole point of injecting one.
        let manager = self.manager
        return try await manager.withMetadataDriver(scope: sourceScope, workload: .bulk) { sourceDriver in
            guard let sourcePlugin = CompareMetadataService.pluginDriver(from: sourceDriver) else {
                throw ObjectCopyError.refused(Self.noSourceDriver)
            }
            return try await manager.withMetadataDriver(
                scope: targetScope, workload: .bulk
            ) { targetDriver in
                guard let targetPlugin = CompareMetadataService.pluginDriver(from: targetDriver) else {
                    throw ObjectCopyError.refused(Self.noTargetDriver)
                }
                let usesTransaction = wrapsInTransaction && targetPlugin.supportsTransactions
                if usesTransaction {
                    try await targetPlugin.beginTransaction(mode: .readWrite)
                }
                do {
                    let outcome = try await copier.copy(
                        from: sourcePlugin,
                        to: targetPlugin
                    ) { rows in
                        progress.setRowsForCurrentObject(rows, completedBefore: completedBefore)
                    }
                    guard usesTransaction else {
                        /// Nothing to roll back, so every batch already flushed is in the target
                        /// whether the user stopped or not.
                        return ObjectCopyRowCopier.Outcome(
                            inserted: outcome.inserted,
                            cancelled: outcome.cancelled,
                            committed: outcome.inserted
                        )
                    }
                    if outcome.cancelled {
                        try? await targetPlugin.rollbackTransaction()
                    } else {
                        try await targetPlugin.commitTransaction()
                    }
                    return outcome
                } catch {
                    if usesTransaction {
                        if errorHandling == .stopAndCommit {
                            try? await targetPlugin.commitTransaction()
                        } else {
                            try? await targetPlugin.rollbackTransaction()
                        }
                    }
                    throw error
                }
            }
        }
    }

    // MARK: - Authorization

    private func authorizationRequest(for plan: ObjectCopyPlan) -> OperationRequest {
        let request = plan.request
        return OperationRequest(
            connectionId: request.target.connectionId,
            databaseType: request.target.databaseType,
            sql: Self.digest(of: plan),
            kind: plan.ddlStatements.isEmpty ? .importData : .schemaMutation,
            caller: .userInterface,
            capabilities: [.mayWrite, .mayRunDestructive, .mayRunMultiStatement, .confirmationPreCleared],
            operationDescription: String(
                format: String(localized: "Copy %1$lld objects to %2$@"),
                plan.tableSteps.count + plan.definitionSteps.count,
                request.target.qualifiedDescription
            )
        )
    }

    nonisolated private static func digest(of plan: ObjectCopyPlan) -> String {
        let script = plan.scriptText
        guard (script as NSString).length > digestCharacterLimit else { return script }
        return (script as NSString).substring(to: digestCharacterLimit)
    }

    nonisolated private static let digestCharacterLimit = 10_000
    nonisolated private static let noSourceDriver = String(localized: "The source driver cannot stream rows.")
    nonisolated private static let noTargetDriver = String(localized: "The target driver cannot be written to.")
}
