//
//  DatabaseAccessBridge+Scripts.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

/// A text an external caller sends where one statement is not the unit: a SQL Server script.
///
/// It takes the route the editor takes for the same text on the same connection. A lone plain query keeps the path
/// that bounds its fetch; anything else a driver that sends batches whole runs batch by batch, cut at `GO` lines, and
/// every result set comes back. The caller's gate has already been cleared for the whole text.
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

    internal func runScript(
        scope: DatabaseScope,
        query: String,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: (any StatementCancellationSignal)?
    ) async throws -> ScriptOutcome {
        guard !Self.statementText(query, grammar: .ansi).isEmpty else {
            throw DatabaseAccessError.invalidArgument(String(localized: "The query is empty."))
        }
        let (driver, databaseType) = try await resolveDriver(scope.connectionId)
        let route = await MainActor.run {
            QueryExecutionRoute.resolve(
                QueryBatchPlanner.batches(
                    in: query,
                    model: QueryStatementModel.forDatabaseType(databaseType),
                    grammar: SQLLexicalResolver.executionGrammar(for: databaseType, connectionId: scope.connectionId)
                ),
                databaseType: databaseType,
                sendsBatchesWhole: driver.supportsResultSetBatches
            )
        }
        switch route {
        case .single(let statement):
            let outcome = try await runStatement(
                scope: scope,
                query: statement.sql,
                maxRows: maxRows,
                timeoutSeconds: timeoutSeconds,
                cancellation: cancellation
            )
            return .statement(outcome.result, executionTimeMs: outcome.executionTimeMs)
        case .batches(let batches):
            return try await runBatches(
                batches,
                of: query,
                scope: scope,
                databaseType: databaseType,
                rowCap: maxRows,
                timeoutSeconds: timeoutSeconds,
                cancellation: cancellation
            )
        case .statements:
            throw DatabaseAccessError.invalidArgument(
                String(localized: "Update the database driver in Settings > Plugins to run several statements in one call.")
            )
        case .needsBatchDriver:
            throw DatabaseAccessError.invalidArgument(
                String(localized: "Update the database driver in Settings > Plugins to run a batch more than once with GO.")
            )
        case nil:
            throw DatabaseAccessError.invalidArgument(String(localized: "The query is empty."))
        }
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
        cancellation: (any StatementCancellationSignal)?
    ) async throws -> ScriptOutcome {
        let classification = QueryClassifier.classify(text, databaseType: databaseType)
        let connectionId = scope.connectionId
        let owner = DriverLeaseOwner()
        let policy: DriverCancellationPolicy = classification.tier == .safe
            ? .cancellableRead(owner)
            : .protectedWrite
        await forwardCancellation(cancellation, to: owner, on: connectionId)

        let route = await MainActor.run { DatabaseManager.shared.executionRoute(for: scope) }
        let startLines = BatchErrorText.lines(of: batches.map(\.range.location), in: text)
        let startTime = CFAbsoluteTimeGetCurrent()
        let statementsRan = CatalogEvent.statementsRan(
            connectionId: connectionId,
            statements: batches.flatMap { $0.statements.map(\.sql) },
            databaseType: databaseType
        )

        let run: ScriptBatchRun
        do {
            run = try await runRacingTimeout(
                scope: scope,
                route: route,
                policy: policy,
                owner: owner,
                timeoutSeconds: timeoutSeconds
            ) { driver in
                try await ScriptBatchRun.run(batches, startLines: startLines, rowCap: rowCap, driver: driver)
            }
        } catch {
            if classification.tier != .safe {
                CatalogChangeService.post(statementsRan)
            }
            throw error
        }

        CatalogChangeService.post(statementsRan)
        return run.outcome(executionTimeMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1_000)
    }
}

/// What a script's batches answered with, and what the session held once they had all run.
struct ScriptBatchRun: Sendable {
    let answers: [QueryBatchResult]
    let sessionState: PluginSessionTransactionState

    /// The session is asked what it holds before and after, as the editor asks: the first answer decides how a
    /// failure reads, and the second whether the script left a transaction open. A batch that raised an error ends the
    /// run as a failure, because a caller reading only the rows would otherwise take a failed write for a done one.
    static func run(
        _ batches: [ExecutableBatch],
        startLines: [Int],
        rowCap: Int,
        driver: DatabaseDriver
    ) async throws -> ScriptBatchRun {
        let plan = BatchTransactionPlan.autocommit.joining(await driver.heldSessionTransactionState())
        var answers: [QueryBatchResult] = []
        for (batch, startLine) in zip(batches, startLines) {
            try Task.checkCancellation()
            let answer = try await repeatedAnswer(to: batch, rowCap: rowCap, driver: driver)
            answers.append(answer)
            guard answer.errors.isEmpty else {
                let context = MultiStatementFailureContext(
                    failure: .batch(sql: batch.sql),
                    errorDescription: BatchErrorText.describe(answer.errors, batchStartLine: startLine) ?? "",
                    executedCount: answers.count,
                    totalCount: batches.count,
                    plan: plan,
                    sessionState: await driver.heldSessionTransactionState(),
                    unit: .batch
                )
                throw DatabaseError.queryFailed(context.report().message)
            }
        }
        return ScriptBatchRun(answers: answers, sessionState: await driver.heldSessionTransactionState())
    }

    /// `GO 5` sends the batch five times and keeps every answer. A repetition that raised an error ends the
    /// repeating, as it ends the run.
    private static func repeatedAnswer(
        to batch: ExecutableBatch,
        rowCap: Int,
        driver: DatabaseDriver
    ) async throws -> QueryBatchResult {
        var combined = QueryBatchResult.empty
        for _ in 0..<max(batch.repeatCount, 1) {
            try Task.checkCancellation()
            let repetition = try await driver.answerBatch(query: batch.sql, rowCap: rowCap, parameters: nil)
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
        let notes = [
            first?.statusMessage,
            BatchRunNotice.text(
                discardedResultSetCount: answers.reduce(0) { $0 + $1.discardedResultSetCount },
                sessionState: sessionState
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
