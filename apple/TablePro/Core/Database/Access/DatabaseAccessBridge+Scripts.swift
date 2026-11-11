//
//  DatabaseAccessBridge+Scripts.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

// A text an external caller sends where one statement is not the unit: a SQL Server script, cut at `GO` lines the
// way the editor cuts it, with every result set coming back.
extension DatabaseAccessBridge {
    internal struct ScriptOutcome: Sendable {
        /// Every result the text returned, in order: a statement's own result, or each result set a script returned.
        internal let resultSets: [QueryResult]

        /// What a caller that reads one result reads. For a statement that is its own result; for a script it is
        /// the first result set, carrying the rows the whole script changed and what the run has to report.
        internal let primary: QueryResult

        internal let executionTimeMs: Double

        internal var rowsReturned: Int {
            resultSets.reduce(0) { $0 + $1.rows.count }
        }

        internal static func statement(_ result: QueryResult, executionTimeMs: Double) -> ScriptOutcome {
            ScriptOutcome(resultSets: [result], primary: result, executionTimeMs: executionTimeMs)
        }
    }

    // An approved statement as a statement; an approved SQL Server script batch by batch at its GO lines.
    internal func runScript(
        _ operation: ApprovedOperation,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: (any StatementCancellationSignal)?
    ) async throws -> ScriptOutcome {
        let reach = DriverReach()
        do {
            return try await runApprovedScript(
                operation, maxRows: maxRows, timeoutSeconds: timeoutSeconds, cancellation: cancellation, reach: reach
            )
        } catch {
            throw await externalError(error, on: operation.scope.connectionId, reach: reach)
        }
    }

    private func runApprovedScript(
        _ operation: ApprovedOperation,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: (any StatementCancellationSignal)?,
        reach: DriverReach
    ) async throws -> ScriptOutcome {
        guard operation.unit == .script else {
            let outcome = try await runStatement(
                operation,
                maxRows: maxRows,
                timeoutSeconds: timeoutSeconds,
                cancellation: cancellation
            )
            return .statement(outcome.result, executionTimeMs: outcome.executionTimeMs)
        }
        guard operation.statements.count == 1, let script = operation.statements.first, script.parameters.isEmpty
        else { throw Self.notApproved }
        let scope = operation.scope
        let (driver, databaseType) = try await resolveDriver(scope.connectionId)
        guard databaseType == operation.databaseType,
              case .batches(let batches)? = await scriptRoute(
                  script.sql, scope: scope, databaseType: databaseType, driver: driver
              )
        else { throw Self.notApproved }
        let outcome = try await runBatches(
            batches,
            of: script.sql,
            scope: scope,
            databaseType: databaseType,
            rowCap: maxRows,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation,
            context: operation.context,
            reach: reach
        )
        let policy = await maskingPolicy(for: scope.connectionId)
        return ScriptOutcome(
            resultSets: outcome.resultSets.map { $0.maskedForExternalCaller(by: policy) },
            primary: outcome.primary.maskedForExternalCaller(by: policy),
            executionTimeMs: outcome.executionTimeMs
        )
    }

    /// Batch by batch on one lease, stopping at the first that raises an error, the way the editor runs them. Every
    /// result set is held to `rowCap`, because a batch has no leading keyword to decide by.
    private func runBatches(
        _ batches: [ExecutableBatch],
        of text: String,
        scope: DatabaseScope,
        databaseType: DatabaseType,
        rowCap: Int,
        timeoutSeconds: Int,
        cancellation: (any StatementCancellationSignal)?,
        context: PluginStatementContext,
        reach: DriverReach
    ) async throws -> ScriptOutcome {
        let classification = QueryClassifier.classify(text, databaseType: databaseType)
        let connectionId = scope.connectionId
        let owner = DriverLeaseOwner()
        let policy: DriverCancellationPolicy = classification.tier == .safe
            ? .cancellableRead(owner)
            : .protectedWrite
        await forwardCancellation(cancellation, to: owner, on: connectionId)

        let manager = await databaseManager
        let route = await MainActor.run { manager.executionRoute(for: scope) }
        let commitMode = await MainActor.run { manager.commitMode(for: connectionId) }
        let statementTexts = batches.flatMap { $0.statements.map(\.sql) }
        let agentGuard = AgentTransactionGuard(
            commitMode: commitMode, databaseType: databaseType, grammar: databaseType.lexicalGrammar,
            connectionId: connectionId
        )
        let writes = classification.tier != .safe
        let startLines = BatchErrorText.lines(of: batches.map(\.range.location), in: text)
        let startTime = CFAbsoluteTimeGetCurrent()
        let statementsRan = CatalogEvent.statementsRan(
            connectionId: connectionId,
            statements: batches.flatMap { $0.statements.map(\.sql) },
            databaseType: databaseType
        )

        let progress = ScriptBatchProgress()
        let run: ScriptBatchRun
        do {
            run = try await runRacingTimeout(
                scope: scope,
                route: route,
                policy: policy,
                owner: owner,
                timeoutSeconds: timeoutSeconds,
                onLateCompletion: { CatalogChangeService.post(statementsRan) }
            ) { driver in
                reach.mark()
                let ran = try await agentGuard.running(statementTexts, writes: writes, on: driver) { opened in
                    do {
                        let answered = try await ScriptBatchRun.run(
                            batches, startLines: startLines, rowCap: rowCap, driver: driver, progress: progress,
                            context: context, commitMode: commitMode, heldByApp: opened
                        )
                        await manager.noteSessionStatements(Self.ranStatements(of: batches, progress), ranOn: driver, scope: scope)
                        return answered
                    } catch {
                        await manager.noteSessionStatements(Self.ranStatements(of: batches, progress), ranOn: driver, scope: scope)
                        throw error
                    }
                }
                var run = ran.value
                run.transactionNotice = ran.notice
                return run
            }
        } catch {
            if classification.tier != .safe {
                CatalogChangeService.post(statementsRan)
            }
            Self.postSucceededBatches(of: batches, progress: progress, scope: scope, databaseType: databaseType)
            throw error
        }

        CatalogChangeService.post(statementsRan)
        Self.postSucceededBatches(of: batches, progress: progress, scope: scope, databaseType: databaseType)
        return run.outcome(executionTimeMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1_000)
    }

    // The batch a script stopped at ran too, and can have created a temporary table before its error.
    private static func ranStatements(of batches: [ExecutableBatch], _ progress: ScriptBatchProgress) -> [String] {
        batches.prefix(progress.completedBatchCount + 1).flatMap { $0.statements.map(\.sql) }
    }

    private static func postSucceededBatches(
        of batches: [ExecutableBatch],
        progress: ScriptBatchProgress,
        scope: DatabaseScope,
        databaseType: DatabaseType
    ) {
        guard let succeeded = progress.succeededStatements(of: batches, scope: scope, databaseType: databaseType) else {
            return
        }
        CatalogChangeService.post(.statementsSucceeded(succeeded))
    }
}

/// How far a script got, and what the session held before and after it, readable after it threw.
final class ScriptBatchProgress: Sendable {
    private struct State {
        var startState: PluginSessionTransactionState = .unknown
        var endState: PluginSessionTransactionState = .unknown
        var completedBatchCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var startState: PluginSessionTransactionState {
        state.withLock { $0.startState }
    }

    var endState: PluginSessionTransactionState {
        state.withLock { $0.endState }
    }

    var completedBatchCount: Int {
        state.withLock { $0.completedBatchCount }
    }

    func begin(in startState: PluginSessionTransactionState) {
        state.withLock { $0.startState = startState }
    }

    func end(in endState: PluginSessionTransactionState) {
        state.withLock { $0.endState = endState }
    }

    func completeBatch() {
        state.withLock { $0.completedBatchCount += 1 }
    }

    /// A batch that finished before a later one failed has already committed on SQL Server, whose
    /// scripts run with no transaction of the app's around them, so what it dropped or renamed is
    /// reported whatever became of the rest. A script stopped by a timeout or a lost connection
    /// never hears what the session held at the end, and adopts nothing.
    func succeededStatements(
        of batches: [ExecutableBatch],
        scope: DatabaseScope,
        databaseType: DatabaseType
    ) -> SucceededStatements? {
        let current = state.withLock { $0 }
        guard current.completedBatchCount > 0 else { return nil }
        return SucceededStatements(
            scope: scope,
            databaseType: databaseType,
            statements: batches.prefix(current.completedBatchCount).flatMap(\.executedStatementTexts),
            commit: .runStartedIn(current.startState, endedIn: current.endState, appTransaction: .none)
        )
    }
}

/// What a script's batches answered with, and what the session held once they had all run.
struct ScriptBatchRun: Sendable {
    let answers: [QueryBatchResult]
    let sessionState: PluginSessionTransactionState
    // What the agent is told instead of "commit or roll it back": the work is pending, or the transaction ended.
    var transactionNotice: String?

    /// The session is asked what it holds before and after, as the editor asks: the first answer decides how a
    /// failure reads, and the second whether the script left a transaction open. A batch that raised an error ends the
    /// run as a failure, because a caller reading only the rows would otherwise take a failed write for a done one.
    static func run(
        _ batches: [ExecutableBatch],
        startLines: [Int],
        rowCap: Int,
        driver: DatabaseDriver,
        progress: ScriptBatchProgress,
        context: PluginStatementContext? = nil,
        commitMode: ConnectionCommitMode = .automatic,
        heldByApp: Bool = false
    ) async throws -> ScriptBatchRun {
        let startState = await driver.heldSessionTransactionState()
        progress.begin(in: startState)
        let plan: BatchTransactionPlan = heldByApp
            ? .heldTransaction
            : BatchTransactionPlan.autocommit.joining(startState, commitMode: commitMode)
        var answers: [QueryBatchResult] = []
        for (batch, startLine) in zip(batches, startLines) {
            try Task.checkCancellation()
            let answer = try await repeatedAnswer(to: batch, rowCap: rowCap, driver: driver, context: context)
            answers.append(answer)
            guard answer.errors.isEmpty else {
                let endState = await driver.heldSessionTransactionState()
                progress.end(in: endState)
                let context = MultiStatementFailureContext(
                    failure: .batch(sql: batch.sql),
                    errorDescription: BatchErrorText.describe(answer.errors, batchStartLine: startLine) ?? "",
                    executedCount: answers.count,
                    totalCount: batches.count,
                    plan: plan,
                    sessionState: endState,
                    unit: .batch
                )
                throw DatabaseError.queryFailed(context.report().message)
            }
            progress.completeBatch()
        }
        let endState = await driver.heldSessionTransactionState()
        progress.end(in: endState)
        return ScriptBatchRun(answers: answers, sessionState: endState)
    }

    /// `GO 5` sends the batch five times and keeps every answer. A repetition that raised an error ends the
    /// repeating, as it ends the run.
    private static func repeatedAnswer(
        to batch: ExecutableBatch,
        rowCap: Int,
        driver: DatabaseDriver,
        context: PluginStatementContext?
    ) async throws -> QueryBatchResult {
        var combined = QueryBatchResult.empty
        for _ in 0..<max(batch.repeatCount, 1) {
            try Task.checkCancellation()
            let repetition = try await driver.answerBatch(
                query: batch.sql, rowCap: rowCap, parameters: nil, context: context
            )
            combined = combined.followed(by: repetition)
            guard repetition.errors.isEmpty else { break }
        }
        return combined
    }

    func outcome(executionTimeMs: Double) -> DatabaseAccessBridge.ScriptOutcome {
        let resultSets = answers.flatMap(\.resultSets)
        let first = resultSets.first
        var primary = QueryResult(
            columns: first?.columns ?? [],
            columnTypes: first?.columnTypes ?? [],
            rows: first?.rows ?? [],
            rowsAffected: answers.reduce(0) { $0 + $1.rowsAffected },
            executionTime: executionTimeMs / 1_000,
            error: nil
        )
        primary.isTruncated = first?.isTruncated ?? false
        primary.columnOrigins = first?.columnOrigins
        let notes = [
            first?.statusMessage,
            transactionNotice,
            BatchRunNotice.text(
                discardedResultSetCount: answers.reduce(0) { $0 + $1.discardedResultSetCount },
                sessionState: transactionNotice == nil ? sessionState : .idle
            )
        ].compactMap { $0 }
        primary.statusMessage = notes.isEmpty ? nil : notes.joined(separator: " ")
        return DatabaseAccessBridge.ScriptOutcome(
            resultSets: resultSets,
            primary: primary,
            executionTimeMs: executionTimeMs
        )
    }
}
