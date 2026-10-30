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

    /// The copy ran on a connection whose session already held a transaction, so what it wrote is
    /// pending inside it and only the user can commit or roll it back. It reaches the target through
    /// `withMetadataDriver`, which is a pooled connection of its own on most engines and the
    /// connection's own session driver on the engines that opt out of pooling.
    internal let pendingInSessionTransaction: Bool

    internal init(
        outcomes: [ObjectCopyObjectOutcome],
        rowsCopied: Int,
        cancelled: Bool,
        createdDatabase: String?,
        pendingInSessionTransaction: Bool = false
    ) {
        self.outcomes = outcomes
        self.rowsCopied = rowsCopied
        self.cancelled = cancelled
        self.createdDatabase = createdDatabase
        self.pendingInSessionTransaction = pendingInSessionTransaction
    }

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

    /// Every failure, each with an identity of its own.
    ///
    /// One object fails once per phase it reaches, so a table whose `CREATE` failed under Skip and
    /// Continue fails again in the data phase with "relation does not exist", and both outcomes
    /// carry the selection's id. Listed by that id a SwiftUI `ForEach` saw a duplicate identifier
    /// and dropped one of the two messages the user needs. The position is what tells them apart,
    /// which is also the order they happened in.
    internal var failures: [ObjectCopyFailure] {
        outcomes.enumerated()
            .filter { $0.element.error != nil }
            .map { ObjectCopyFailure(id: $0.offset, outcome: $0.element) }
    }
}

internal struct ObjectCopyFailure: Identifiable, Sendable {
    internal let id: Int
    internal let outcome: ObjectCopyObjectOutcome
}

@MainActor
internal struct ObjectCopyRunner {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ObjectCopyRunner")

    private let manager: any ScopedMetadataProviding
    private let gate: ExecutionGate

    internal init(
        manager: any ScopedMetadataProviding = DatabaseManager.shared,
        gate: ExecutionGate = ExecutionGateProvider.shared
    ) {
        self.manager = manager
        self.gate = gate
    }

    /// Who owns the transaction this phase's statements run inside, asked of the target driver
    /// inside the same lease that runs them so nothing can open one between the answer and the
    /// first statement.
    ///
    /// The copy reaches its target through `withMetadataDriver`, which is a pooled connection of its
    /// own on most engines and the connection's own session driver on the engines that opt out of
    /// pooling (DuckDB, PGlite). On those the session can already hold the user's transaction, and a
    /// `BEGIN` of the copy's own aborts it on DuckDB while a `COMMIT` of its own commits their
    /// pending work. `DataWriteExecutor`, `DatabaseManager+Principals` and
    /// `StructureRebuildPlanRunner` ask the same question for the same reason.
    nonisolated private static func transactionOwner(of driver: DatabaseDriver) async -> WriteTransactionOwner {
        WriteTransactionOwner.resolve(
            supportsTransactions: driver.supportsTransactions,
            sessionState: await driver.heldSessionTransactionState()
        )
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
        var pendingInSessionTransaction = false

        func finished() -> ObjectCopyRunResult {
            ObjectCopyRunResult(
                outcomes: outcomes,
                rowsCopied: rowsCopied,
                cancelled: cancelled,
                createdDatabase: createdDatabase,
                pendingInSessionTransaction: pendingInSessionTransaction
            )
        }

        /// Torn down before anything is built, and children first, so a foreign key is gone before
        /// the table it points at and a trigger before the table that owns it. One parent-first
        /// pass had every DROP rejected by the constraint below it.
        ///
        /// Both phases run under one `withMetadataDriver` call, in a transaction or with foreign
        /// key checks off. Split across two calls, a Stop between them or a failing first CREATE
        /// left every later object dropped with nothing put back.
        if !(plan.schemaStatements + plan.cleanupStatements + plan.creationStatements).isEmpty {
            let result = try await runStructure(plan, request: request, progress: progress)
            outcomes += result.outcomes
            cancelled = cancelled || result.cancelled
            pendingInSessionTransaction = pendingInSessionTransaction || result.joinedSessionTransaction
            if result.stopped { return finished() }
        }

        /// Every table the copy will append to is emptied before any of them is filled, children
        /// first. Clearing each one immediately before its own rows meant the first parent DELETE
        /// met child rows that were still there, and a cascading key took rows out of tables the
        /// user had not selected.
        ///
        /// A run that promises a rollback empties them inside the data phase's own transaction
        /// instead, because a DELETE that has already committed cannot be taken back by anything
        /// that fails afterwards. Only a run that promises nothing clears here.
        var uncleared: Set<String> = []
        if !cancelled, !plan.clearGroups.isEmpty, !plan.clearsInsideDataTransaction {
            let result = try await runDDL(plan.clearGroups, request: request, progress: progress)
            let failures = result.outcomes.filter { $0.error != nil }
            outcomes += failures
            // A table that kept its own rows would get the source's on top of them.
            uncleared = Set(failures.map(\.id))
            cancelled = cancelled || result.cancelled
            pendingInSessionTransaction = pendingInSessionTransaction || result.joinedSessionTransaction
            if result.stopped { return finished() }
        }

        if !cancelled, request.content.includesData {
            let dataOutcomes = try await runData(plan, skipping: uncleared, request: request, progress: progress)
            outcomes += dataOutcomes.outcomes
            cancelled = cancelled || dataOutcomes.cancelled
            rowsCopied = dataOutcomes.rowsCopied
            pendingInSessionTransaction = pendingInSessionTransaction || dataOutcomes.joinedSessionTransaction
            if dataOutcomes.stopped { return finished() }
        }

        /// A trigger fires on the rows the copy writes, so it goes in once they are in. Installed
        /// with the rest of the DDL, duplicating a database with an audit trigger produced a
        /// second audit row for every row copied.
        if !cancelled, !plan.afterDataGroups.isEmpty {
            let result = try await runDDL(plan.afterDataGroups, request: request, progress: progress)
            outcomes += result.outcomes
            cancelled = cancelled || result.cancelled
            pendingInSessionTransaction = pendingInSessionTransaction || result.joinedSessionTransaction
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
        /// True when the phase ran inside a transaction the session already held.
        var joinedSessionTransaction = false
    }

    /// Every drop and every create, in one scoped call, wrapped where the engine allows it.
    ///
    /// A replacement is destructive only in the moment between its DROP and its CREATE, so the two
    /// have to be one unit as far as the engine can make them: a transaction where DDL is
    /// transactional and the run promises a rollback, and otherwise at least one connection lease
    /// with foreign key checks off so the ordering cannot fail half way.
    private func runStructure(
        _ plan: ObjectCopyPlan,
        request: ObjectCopyRequest,
        progress: ObjectCopyProgress
    ) async throws -> DDLResult {
        let tableGroups = plan.cleanupGroups + plan.tableCreationGroups
        let definitionGroups = plan.definitionCreationGroups
        let errorHandling = request.errorHandling
        let scope = request.target.scope
        let hasCleanup = !plan.cleanupGroups.isEmpty
        let schemaStatements = plan.schemaStatements
        // A MySQL DROP refuses a table another references, and a CREATE a key to a table not there
        // yet, which a cycle always has. Past a replacement, a key to a table outside the copy keeps
        // the checks, so it still fails when that table is missing.
        let dropsTables = plan.cleanupGroups.contains { !$0.statements.isEmpty }
        let relaxesKeys = tableGroups.contains { !$0.statements.isEmpty } && (dropsTables || plan.keysInside.created)
        let pinsSession = plan.isStructureReadPinned && VerbatimTransferScopes.isSameEngine(
            source: request.source.databaseType, target: request.target.databaseType
        )

        return try await manager.withMetadataDriver(scope: scope) { driver in
            guard let plugin = CompareMetadataService.pluginDriver(from: driver) else {
                throw ObjectCopyError.refused(Self.noTargetDriver)
            }
            let owner = await Self.transactionOwner(of: driver)
            // The other two settings keep what ran, and PostgreSQL commits an aborted transaction as a ROLLBACK.
            let usesTransaction = hasCleanup && errorHandling == .stopAndRollback
                && plugin.supportsTransactionalDDL && owner.opensTransaction
            if usesTransaction { try await plugin.beginTransaction(mode: .readWrite) }

            var result: DDLResult
            do {
                result = try await Self.withForeignKeysRelaxed(
                    on: plugin, when: relaxesKeys && !usesTransaction && owner != .session
                ) { _ in
                    try await Self.executeTableDDL(
                        schemaStatements: schemaStatements,
                        groups: tableGroups,
                        on: plugin,
                        pinsSession: pinsSession,
                        errorHandling: errorHandling,
                        progress: progress
                    )
                }
            } catch {
                // The pool never ends a transaction, so the next lease would inherit an aborted one.
                if usesTransaction { try? await plugin.rollbackTransaction() }
                throw error
            }
            /// Outside the write scope, because a routine or trigger records the session's
            /// `sql_mode`: it gets its own creation settings, or else the target's.
            if !result.stopped {
                let definitions = await Self.execute(
                    definitionGroups, on: plugin, errorHandling: errorHandling, progress: progress
                )
                result.outcomes += definitions.outcomes
                result.cancelled = definitions.cancelled
                result.stopped = definitions.stopped
            }
            result.joinedSessionTransaction = owner == .session

            guard usesTransaction else { return result }
            guard result.stopped else {
                do {
                    try await plugin.commitTransaction()
                } catch {
                    try? await plugin.rollbackTransaction()
                    throw error
                }
                return result
            }
            try? await plugin.rollbackTransaction()
            return Self.withoutSuccesses(result)
        }
    }

    /// What is left of a phase whose transaction was rolled back: the failures, and nothing else.
    ///
    /// Each object appended its own outcome as it ran, so a phase that stopped on the eighth table
    /// carried seven successes into a result the rollback had already undone. The summary then
    /// reported seven objects copied over a target where nothing was written.
    nonisolated private static func withoutSuccesses(_ result: DDLResult) -> DDLResult {
        var rolled = result
        rolled.outcomes = result.outcomes.filter { $0.error != nil }
        return rolled
    }

    /// The schemas, drops and tables, under the target's write scope on a same-engine copy: a
    /// `CREATE TABLE` read from the source can carry a default, such as MySQL's `'0000-00-00'`, that
    /// the target session's own mode refuses. The scope never outlives this lease.
    nonisolated private static func executeTableDDL(
        schemaStatements: [SyncStatement],
        groups: [ObjectCopyStatementGroup],
        on driver: any PluginDatabaseDriver,
        pinsSession: Bool,
        errorHandling: ImportErrorHandling,
        progress: ObjectCopyProgress
    ) async throws -> DDLResult {
        let writesAnything = !schemaStatements.isEmpty || groups.contains { !$0.statements.isEmpty }
        let scopes = pinsSession && writesAnything
            ? await VerbatimTransferScopes.open(writing: SessionScopeHandle(driver))
            : nil
        do {
            /// Ahead of everything, and it throws rather than being attributed to an object: no
            /// table, view or routine can be created if the schema naming it is not there, so
            /// carrying on would report every one of them as its own failure for one cause.
            for statement in schemaStatements {
                _ = try await driver.execute(query: statement.sql)
            }
            let result = await execute(groups, on: driver, errorHandling: errorHandling, progress: progress)
            await scopes?.close()
            return result
        } catch {
            await scopes?.close()
            throw error
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
            let opened = await openSettings(of: group, on: driver)
            do {
                for statement in group.statements {
                    _ = try await driver.execute(query: statement.sql)
                }
                if opened { await closeSettings(of: group, on: driver) }
                result.outcomes.append(ObjectCopyObjectOutcome(
                    selection: group.selection, rowsCopied: 0, error: nil
                ))
            } catch {
                if opened { await closeSettings(of: group, on: driver) }
                logger.error(
                    "Copy DDL failed for \(group.selection.qualifiedName, privacy: .public): \(error.publicLogShape, privacy: .public)"
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

    /// True once any opening statement ran, so the closing puts back what it changed. One that fails
    /// leaves the object to be created under the session's own settings, as it was before these.
    nonisolated private static func openSettings(
        of group: ObjectCopyStatementGroup,
        on driver: any PluginDatabaseDriver
    ) async -> Bool {
        var ranAny = false
        for statement in group.opening {
            do {
                _ = try await driver.execute(query: statement.sql)
                ranAny = true
            } catch {
                logger.warning(
                    "Creation settings for \(group.selection.qualifiedName, privacy: .public) were not applied: \(error.publicLogShape, privacy: .public)"
                )
                break
            }
        }
        return ranAny
    }

    /// Parents already come first, but a cycle, a self reference whose child row comes first, or a
    /// source row that already breaks a key is written only with the target's checks off.
    nonisolated private static func withForeignKeysRelaxed<T>(
        on plugin: any PluginDatabaseDriver,
        when relaxes: Bool,
        _ body: (_ relaxed: Bool) async throws -> T
    ) async throws -> T {
        guard relaxes else { return try await body(false) }
        let opened: PluginSessionScope?
        do {
            opened = try await plugin.openSessionScope(for: .relaxedForeignKeys)
        } catch {
            logger.warning("Copying with foreign key checks on: \(error.publicLogShape, privacy: .public)")
            opened = nil
        }
        guard let scope = opened else { return try await body(false) }
        // Shielded like a rollback: the connection goes back to the pool after this lease.
        func close() async {
            do {
                try await TaskCancellationShield.run { try await plugin.closeSessionScope(scope) }
            } catch {
                logger.error("Restoring foreign key checks failed: \(error.publicLogShape, privacy: .public)")
            }
        }
        do {
            let value = try await body(true)
            await close()
            return value
        } catch {
            await close()
            throw error
        }
    }

    /// Each statement shielded like a rollback: the connection goes back to the pool after this
    /// lease, and a setting left behind would apply to whatever leases it next.
    nonisolated private static func closeSettings(
        of group: ObjectCopyStatementGroup,
        on driver: any PluginDatabaseDriver
    ) async {
        for statement in group.closing {
            do {
                try await TaskCancellationShield.run { _ = try await driver.execute(query: statement.sql) }
            } catch {
                logger.error(
                    "Restoring settings after \(group.selection.qualifiedName, privacy: .public) failed: \(error.publicLogShape, privacy: .public)"
                )
            }
        }
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
            let owner = await Self.transactionOwner(of: driver)
            var result = await Self.execute(
                runnable, on: plugin, errorHandling: errorHandling, progress: progress
            )
            result.joinedSessionTransaction = owner == .session
            return result
        }
    }

    // MARK: - Data

    private struct DataResult {
        var outcomes: [ObjectCopyObjectOutcome] = []
        var cancelled = false
        var stopped = false
        /// True when the rows went into a transaction the session already held.
        var joinedSessionTransaction = false
        /// Every row written, a stopped or failed table's included. A rollback takes the count back
        /// with the rows; a target that opened no transaction keeps both, and leaving them out
        /// would send a retry over them.
        var rowsCopied = 0

        mutating func recordCopy(of step: ObjectCopyTableStep, inserted: Int) {
            rowsCopied += inserted
            outcomes.append(ObjectCopyObjectOutcome(selection: step.selection, rowsCopied: inserted, error: nil))
        }

        /// Stop reaching the driver mid-stream is the user stopping, not the copy failing, and the
        /// two produce different notifications.
        mutating func recordStop(of step: ObjectCopyTableStep, inserted: Int, progress: ObjectCopyProgress) {
            cancelled = true
            stopped = true
            if inserted > 0 { recordCopy(of: step, inserted: inserted) }
            progress.setRowsForCurrentObject(0, completedBefore: rowsCopied)
        }

        /// False when the run stops here.
        mutating func recordFailure(
            of step: ObjectCopyTableStep,
            _ error: any Error,
            errorHandling: ImportErrorHandling,
            progress: ObjectCopyProgress
        ) -> Bool {
            ObjectCopyRunner.logger.error(
                "Copy rows failed for \(step.qualifiedTargetName, privacy: .public): \(error.publicLogShape, privacy: .public)"
            )
            let written = (error as? ObjectCopyRowCopier.PartialFailure)?.written ?? 0
            rowsCopied += written
            progress.setRowsForCurrentObject(0, completedBefore: rowsCopied)
            outcomes.append(ObjectCopyObjectOutcome(
                selection: step.selection, rowsCopied: written, error: error.localizedDescription
            ))
            guard errorHandling == .skipAndContinue else {
                stopped = true
                return false
            }
            return true
        }
    }

    private func runData(
        _ plan: ObjectCopyPlan,
        skipping uncleared: Set<String>,
        request: ObjectCopyRequest,
        progress: ObjectCopyProgress
    ) async throws -> DataResult {
        guard plan.dataRunsInOneTransaction else {
            let steps = plan.dataSteps.filter { !uncleared.contains($0.id) }
            return await runIndependentTables(steps, request: request, progress: progress)
        }
        return try await runInOneTransaction(plan, request: request, progress: progress)
    }

    /// Every clear and every row, in one transaction on the target.
    ///
    /// Emptying a table is reversible only while the transaction that emptied it is still open, so
    /// the clears cannot run in a phase of their own once the run has promised a rollback. They
    /// still all run before any table is filled, which is what keeps a cascading foreign key from
    /// taking rows out of a table the user never selected.
    ///
    /// The rows relax the target's checks only here, where a failure takes every one of them back:
    /// committed table by table, a cycle's first table would keep rows pointing at a second that
    /// then failed.
    private func runInOneTransaction(
        _ plan: ObjectCopyPlan,
        request: ObjectCopyRequest,
        progress: ObjectCopyProgress
    ) async throws -> DataResult {
        let manager = self.manager
        let clearGroups = plan.clearGroups
        let steps = plan.dataSteps
        let sourceType = request.source.databaseType
        let targetType = request.target.databaseType
        let sourceScope = request.source.scope
        let errorHandling = request.errorHandling
        let relaxesRows = plan.keysInside.rows

        /// A lease this phase cannot take is a run-level failure with no object to pin it on, and
        /// it is thrown for the same reason the DDL phases throw it: swallowed into a stopped
        /// result it left the sheet reporting a copy that did nothing and saying nothing about why.
        return try await manager.withMetadataDriver(
            scope: request.target.scope, workload: .bulk
        ) { targetDriver in
            guard let targetPlugin = CompareMetadataService.pluginDriver(from: targetDriver) else {
                throw ObjectCopyError.refused(Self.noTargetDriver)
            }
            let owner = await Self.transactionOwner(of: targetDriver)
            let usesTransaction = owner.opensTransaction
            if usesTransaction { try await targetPlugin.beginTransaction(mode: .readWrite) }

            var result = DataResult()
            result.joinedSessionTransaction = owner == .session
            // Checks stay on for the clears: a table outside the copy that references a cleared one
            // keeps its own ON DELETE rule, and MySQL cannot prove no other database holds one.
            let cleared = await Self.execute(
                clearGroups, on: targetPlugin, errorHandling: errorHandling, progress: progress
            )
            result.outcomes += cleared.outcomes.filter { $0.error != nil }
            result.cancelled = cleared.cancelled
            result.stopped = cleared.stopped

            if !result.stopped {
                // Every table here was just created, so the checks cost nothing yet. One the account
                // may not run, such as a SELECT on a write-only login, keeps the target's checks on.
                let checkable = usesTransaction && relaxesRows
                    ? await Self.keyChecksRun(steps, on: targetPlugin)
                    : false
                try await Self.withForeignKeysRelaxed(on: targetPlugin, when: checkable) { relaxed in
                    let copied = await Self.stream(
                        steps,
                        from: sourceScope,
                        into: targetPlugin,
                        manager: manager,
                        sourceType: sourceType,
                        targetType: targetType,
                        errorHandling: errorHandling,
                        progress: progress
                    )
                    result.outcomes += copied.outcomes
                    result.cancelled = result.cancelled || copied.cancelled
                    result.stopped = copied.stopped
                    result.rowsCopied = copied.rowsCopied
                    // A row read while the source was changing, or one the source already broke,
                    // fails here rather than committing past keys nothing checks again.
                    if relaxed, !result.stopped {
                        await Self.checkKeys(of: steps, on: targetPlugin, into: &result, progress: progress)
                    }
                }
            }

            guard usesTransaction else { return result }
            guard result.stopped else {
                /// A commit that fails leaves the transaction open, and the clears are inside it,
                /// so it is rolled back rather than left for the lease to decide.
                do {
                    try await targetPlugin.commitTransaction()
                } catch {
                    try? await targetPlugin.rollbackTransaction()
                    throw error
                }
                return result
            }
            try? await targetPlugin.rollbackTransaction()
            /// Nothing may be reported as copied that the rollback took back, and no such table as
            /// done. A table the engine keeps through a ROLLBACK still holds its rows, and leaving
            /// them out would send a retry over them.
            let kept = Set(steps.filter { !$0.rollsBack }.map(\.id))
            result.outcomes = result.outcomes.compactMap { outcome in
                if kept.contains(outcome.id) { return outcome }
                guard let error = outcome.error else { return nil }
                return ObjectCopyObjectOutcome(selection: outcome.selection, rowsCopied: 0, error: error)
            }
            result.rowsCopied = result.outcomes.filter { kept.contains($0.id) }.reduce(0) { $0 + $1.rowsCopied }
            return result
        }
    }

    /// Every table streamed into a target driver the caller already holds, so one transaction can
    /// span all of them. The source is leased per table, because only the target's lease has to
    /// outlive the loop.
    nonisolated private static func stream(
        _ steps: [ObjectCopyTableStep],
        from sourceScope: DatabaseScope,
        into targetPlugin: any PluginDatabaseDriver,
        manager: any ScopedMetadataProviding,
        sourceType: DatabaseType,
        targetType: DatabaseType,
        errorHandling: ImportErrorHandling,
        progress: ObjectCopyProgress
    ) async -> DataResult {
        var result = DataResult()
        for step in steps {
            if progress.isCancelled || Task.isCancelled {
                result.cancelled = true
                result.stopped = true
                break
            }
            progress.startObject(step.qualifiedTargetName)
            let copier = ObjectCopyRowCopier(
                step: step, sourceDatabaseType: sourceType, targetDatabaseType: targetType
            )
            let completedBefore = result.rowsCopied
            do {
                let outcome = try await manager.withMetadataDriver(
                    scope: sourceScope, workload: .bulk
                ) { sourceDriver in
                    guard let sourcePlugin = CompareMetadataService.pluginDriver(from: sourceDriver) else {
                        throw ObjectCopyError.refused(noSourceDriver)
                    }
                    return try await copier.copy(from: sourcePlugin, to: targetPlugin) { rows in
                        progress.setRowsForCurrentObject(rows, completedBefore: completedBefore)
                    }
                }
                guard !outcome.cancelled else {
                    result.recordStop(of: step, inserted: outcome.inserted, progress: progress)
                    break
                }
                result.recordCopy(of: step, inserted: outcome.inserted)
            } catch is CancellationError {
                result.recordStop(of: step, inserted: 0, progress: progress)
                break
            } catch {
                guard result.recordFailure(of: step, error, errorHandling: errorHandling, progress: progress) else { break }
            }
        }
        return result
    }

    /// Each batch commits as it is written, so a failure keeps what ran before it, and the target's
    /// checks stay on: past a stop or a skipped failure a child's parent rows can be missing. Both
    /// scopes are open at once, which the planner has already established is safe: two scopes on
    /// one connection are refused unless both route to the pool.
    private func runIndependentTables(
        _ steps: [ObjectCopyTableStep],
        request: ObjectCopyRequest,
        progress: ObjectCopyProgress
    ) async -> DataResult {
        var result = DataResult()
        let targetType = request.target.databaseType

        for step in steps {
            if progress.isCancelled || Task.isCancelled {
                result.cancelled = true
                result.stopped = true
                break
            }
            progress.startObject(step.qualifiedTargetName)

            do {
                let copied = try await copyRows(
                    step,
                    request: request,
                    targetType: targetType,
                    completedBefore: result.rowsCopied,
                    progress: progress
                )
                let outcome = copied.outcome
                result.joinedSessionTransaction =
                    result.joinedSessionTransaction || copied.joinedSessionTransaction
                guard !outcome.cancelled else {
                    result.recordStop(of: step, inserted: outcome.inserted, progress: progress)
                    break
                }
                result.recordCopy(of: step, inserted: outcome.inserted)
            } catch is CancellationError {
                result.recordStop(of: step, inserted: 0, progress: progress)
                break
            } catch {
                guard result.recordFailure(
                    of: step, error, errorHandling: request.errorHandling, progress: progress
                ) else { break }
            }
        }
        return result
    }

    /// One table's rows, and whether they went into a transaction the session already held.
    private struct CopiedRows: Sendable {
        let outcome: ObjectCopyRowCopier.Outcome
        let joinedSessionTransaction: Bool
    }

    private func copyRows(
        _ step: ObjectCopyTableStep,
        request: ObjectCopyRequest,
        targetType: DatabaseType,
        completedBefore: Int,
        progress: ObjectCopyProgress
    ) async throws -> CopiedRows {
        let sourceScope = request.source.scope
        let targetScope = request.target.scope
        let copier = ObjectCopyRowCopier(
            step: step, sourceDatabaseType: request.source.databaseType, targetDatabaseType: targetType
        )

        /// The injected manager on both sides. Reaching for the singleton on the target bypassed
        /// the caller's own connections and routing, which is the whole point of injecting one.
        let manager = self.manager
        // Target first, as `runInOneTransaction` takes them: two copies taking the two leases in
        // opposite orders could each hold the one the other waits for.
        return try await manager.withMetadataDriver(scope: targetScope, workload: .bulk) { targetDriver in
            guard let targetPlugin = CompareMetadataService.pluginDriver(from: targetDriver) else {
                throw ObjectCopyError.refused(Self.noTargetDriver)
            }
            let owner = await Self.transactionOwner(of: targetDriver)
            return try await manager.withMetadataDriver(
                scope: sourceScope, workload: .bulk
            ) { sourceDriver in
                guard let sourcePlugin = CompareMetadataService.pluginDriver(from: sourceDriver) else {
                    throw ObjectCopyError.refused(Self.noSourceDriver)
                }
                let outcome = try await copier.copy(from: sourcePlugin, to: targetPlugin) { rows in
                    progress.setRowsForCurrentObject(rows, completedBefore: completedBefore)
                }
                return CopiedRows(outcome: outcome, joinedSessionTransaction: owner == .session)
            }
        }
    }

    nonisolated private static func keyChecksRun(
        _ steps: [ObjectCopyTableStep],
        on driver: any PluginDatabaseDriver
    ) async -> Bool {
        for check in steps.flatMap({ $0.keyChecks ?? [] }) {
            do {
                _ = try await driver.execute(query: check.sql)
            } catch {
                logger.warning(
                    "Copying with foreign key checks on, \(check.constraint, privacy: .public) cannot be checked: \(error.publicLogShape, privacy: .public)"
                )
                return false
            }
        }
        return true
    }

    /// Stops at the first key that fails, since the rollback that follows takes back every table.
    nonisolated private static func checkKeys(
        of steps: [ObjectCopyTableStep],
        on driver: any PluginDatabaseDriver,
        into result: inout DataResult,
        progress: ObjectCopyProgress
    ) async {
        for step in steps {
            for check in step.keyChecks ?? [] {
                if progress.isCancelled || Task.isCancelled {
                    result.cancelled = true
                    result.stopped = true
                    return
                }
                let failure: String
                do {
                    let counted = try await driver.execute(query: check.sql).rows.first?.first?.asText
                    guard let broken = counted.flatMap(Int.init), broken > 0 else { continue }
                    failure = String(
                        format: String(localized: "Rows in %1$@ break the foreign key %2$@."),
                        step.qualifiedTargetName, check.constraint
                    )
                } catch {
                    failure = error.localizedDescription
                }
                result.outcomes.append(ObjectCopyObjectOutcome(selection: step.selection, rowsCopied: 0, error: failure))
                result.stopped = true
                return
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
