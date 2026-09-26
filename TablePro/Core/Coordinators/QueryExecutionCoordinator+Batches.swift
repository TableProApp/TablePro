//
//  QueryExecutionCoordinator+Batches.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

/// One batch of a run, resolved before the lease is taken.
private struct PreparedBatch: @unchecked Sendable {
    let batch: ExecutableBatch
    /// The batch's text with any `:name` parameter rewritten into the driver's own placeholder.
    let sentSQL: String
    let parameterValues: [Any?]?
    let rowCap: Int?
    /// The editor line the batch's first line sits on, so a line the server reports can be found there.
    let startLine: Int
    /// A batch that is nothing but the script's own `COMMIT` gets the same protection a statement would.
    let isCommitPoint: Bool
}

/// What one batch answered with, however many times the script asked for it.
private struct BatchOutput: Sendable {
    let resultSets: [QueryResult]
    let rowsAffected: Int
    let errors: [PluginBatchError]
    let discardedResultSetCount: Int
    let executionTime: TimeInterval
    let errorDescription: String?
    var serverOutput: PluginServerOutput = .none

    var summary: BatchSummary {
        let returned = resultSets.reduce(0) { $0 + $1.rows.count }
        return BatchSummary(rowCount: resultSets.isEmpty ? rowsAffected : returned, executionTime: executionTime)
    }
}

/// What query history records for one batch: the rows it returned, or the rows it wrote when it returned none.
private struct BatchSummary {
    let rowCount: Int
    let executionTime: TimeInterval
}

/// The lines a batch printed across its repetitions, capped the way one request's output is.
private struct BatchPrintedOutput {
    private static let lineLimit = 10_000

    private var lines: [String] = []
    private var isTruncated = false

    mutating func append(_ output: PluginServerOutput) {
        isTruncated = isTruncated || output.isTruncated
        let room = max(Self.lineLimit - lines.count, 0)
        lines += output.lines.prefix(room)
        if output.lines.count > room { isTruncated = true }
    }

    var output: PluginServerOutput {
        PluginServerOutput(lines: lines, isTruncated: isTruncated)
    }
}

private struct BatchRun {
    let outcome: BatchStatementOutcome<BatchOutput>
    let plan: BatchTransactionPlan
    let sessionState: PluginSessionTransactionState
    var failureOutput: PluginServerOutput = .none
}

extension QueryExecutionCoordinator {
    /// The batches `text` runs as on this connection. `sourceOffset` moves them onto the tab's whole query when
    /// `text` is a selection or a single statement taken from it.
    func executionBatches(in text: String, sourceOffset: Int = 0) -> [ExecutableBatch] {
        QueryBatchPlanner.batches(
            in: text, model: parent.statementModel, grammar: parent.lexicalGrammar, sourceOffset: sourceOffset
        )
    }

    func executionRoute(for batches: [ExecutableBatch]) -> QueryExecutionRoute? {
        QueryExecutionRoute.resolve(
            batches,
            databaseType: parent.connection.type,
            sendsBatchesWhole: DatabaseManager.shared.driver(for: parent.connectionId)?.supportsResultSetBatches ?? false
        )
    }

    /// Runs each batch whole, in order, on one lease, and stops at the first that fails.
    ///
    /// The app opens no transaction around the run, as SQL Server's own tools do not: a batch carries on past most
    /// errors, so an app-owned rollback would take back statements that ran after the failure, and the script's own
    /// `BEGIN TRAN`, `TRY...CATCH` and procedures are what decide. A transaction the script leaves open is reported.
    func executeBatches(
        _ batches: [ExecutableBatch],
        parameters: [QueryParameter],
        bypassRowLimit: Bool = false
    ) {
        guard let (selectedTab, index) = parent.tabManager.selectedTabAndIndex,
              !parent.tabExecution.isExecuting(selectedTab.id) else { return }

        if let firstMissing = parameters.first(where: {
            !$0.isNull && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            parent.tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(
                    format: String(localized: "Missing value for parameter: %@"),
                    ":\(firstMissing.name)"
                )
            }
            return
        }

        guard let scope = parent.scope(for: selectedTab) else {
            parent.tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(localized: "Not connected to database")
            }
            return
        }

        parent.tabManager.mutate(at: index) { tab in
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
        }

        let conn = parent.connection
        let tabId = selectedTab.id
        let (claim, lease) = parent.beginTabExecution(for: tabId)
        let prepared = prepareBatches(
            batches,
            parameters: parameters,
            query: selectedTab.content.query,
            bypassRowLimit: bypassRowLimit
        )
        let statementTexts = batches.flatMap { $0.statements.map(\.sql) }
        let mode = OperationKind.worst(of: statementTexts, databaseType: conn.type).transactionAccessMode

        let batchTask = Task { [weak self, parent] in
            guard let self else { return }
            let run = await runBatches(prepared, scope: scope, mode: mode, claim: claim, lease: lease)
            postRanStatements(of: prepared, outcome: run.outcome, connection: conn)

            let sessionNotice = Self.runNotice(outcome: run.outcome, sessionState: run.sessionState)
            switch run.outcome {
            case .cancelled(let outputs):
                guard parent.tabExecution.settle(claim) else { return }
                parent.retireQueryTask(.claim(claim))
                keepStoppedBatches(prepared, outputs: outputs, parameters: parameters, tabId: tabId, sessionNotice: sessionNotice)
                parent.reportEndedExecutions([
                    EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
                ])
            case .completed(let outputs):
                applyCompletedBatches(
                    prepared, outputs: outputs, parameters: parameters,
                    tabId: tabId, claim: claim, sessionNotice: sessionNotice
                )
            case .failed(let outputs, let failure, let errorDescription):
                handleBatchFailure(
                    MultiStatementFailureContext(
                        failure: failure,
                        errorDescription: errorDescription,
                        executedCount: outputs.count,
                        totalCount: prepared.count,
                        plan: run.plan,
                        sessionState: run.sessionState,
                        unit: .batch
                    ),
                    prepared: prepared,
                    outputs: outputs,
                    parameters: parameters,
                    tabId: tabId,
                    claim: claim,
                    failureOutput: run.failureOutput
                )
            }
        }
        parent.installQueryTask(batchTask, owner: .claim(claim), lease: lease)
    }

    // MARK: - Preparation

    private func prepareBatches(
        _ batches: [ExecutableBatch],
        parameters: [QueryParameter],
        query: String,
        bypassRowLimit: Bool
    ) -> [PreparedBatch] {
        let style = PluginMetadataRegistry.shared.snapshot(for: parent.connection.type)?.parameterStyle ?? .questionMark
        let rowCap = batchRowCap(bypassLimit: bypassRowLimit)
        let grammar = parent.lexicalGrammar
        let startLines = BatchErrorText.lines(of: batches.map(\.range.location), in: query)
        return zip(batches, startLines).map { batch, startLine in
            let bindsParameters = !parameters.isEmpty && batch.acceptsBindParameters
                && !SQLParameterExtractor.extractParameters(from: batch.sql).isEmpty
            let conversion = bindsParameters
                ? SQLParameterExtractor.convertToNativeStyle(sql: batch.sql, parameters: parameters, style: style)
                : nil
            let isCommitPoint = batch.statements.count == 1
                && batch.statements.allSatisfy { BatchCommitStatement.matches($0.sql, grammar: grammar) }
            return PreparedBatch(
                batch: batch,
                sentSQL: conversion?.sql ?? batch.sql,
                parameterValues: conversion?.values,
                rowCap: rowCap,
                startLine: startLine,
                isCommitPoint: isCommitPoint
            )
        }
    }

    /// A batch has no leading keyword to decide by: a script that opens with `DECLARE` returns rows as surely as one
    /// that opens with `SELECT`, so every result set it returns is held to the setting's cap.
    private func batchRowCap(bypassLimit: Bool) -> Int? {
        let dataGrid = AppSettingsManager.shared.dataGrid
        guard !bypassLimit, dataGrid.truncateQueryResults else { return nil }
        let cap = dataGrid.validatedQueryResultRowCap
        return cap > 0 ? cap : nil
    }

    // MARK: - Running

    /// The session is asked what it holds before and after every run, whatever the batches were: T-SQL needs no `;`,
    /// so a `BEGIN TRAN` and the `UPDATE` after it can be one statement to the scanner and still leave a transaction
    /// open. The first answer decides how a failure reads: work done inside a transaction the user already had open
    /// is pending in it, or gone with it, and never simply applied.
    private func runBatches(
        _ prepared: [PreparedBatch],
        scope: DatabaseScope,
        mode: PluginTransactionAccessMode,
        claim: TabExecutionClaim,
        lease: DriverLeaseOwner
    ) async -> BatchRun {
        let failureOutput = ServerOutputBox()
        do {
            var run = try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: DatabaseManager.shared.executionRoute(for: scope),
                cancellation: .cancellableRead(lease)
            ) { driver in
                let plan = BatchTransactionPlan.autocommit.joining(await driver.heldSessionTransactionState())
                let outcome = await BatchStatementRun.run(
                    prepared,
                    plan: plan,
                    mode: mode,
                    driver: driver,
                    connectionId: scope.connectionId,
                    gate: self.claimGate(for: claim),
                    failureSQL: \.batch.sql,
                    isCommitPoint: \.isCommitPoint,
                    serverError: \.errorDescription
                ) { batch in
                    try await Self.runBatch(batch, driver: driver, failureOutput: failureOutput)
                }
                let sessionState = await driver.heldSessionTransactionState()
                return BatchRun(outcome: outcome, plan: plan, sessionState: sessionState)
            }
            run.failureOutput = failureOutput.output
            return run
        } catch {
            if DatabaseCancellationDiagnosis.isCancellation(error) || Task.isCancelled {
                return BatchRun(outcome: .cancelled(results: []), plan: .autocommit, sessionState: .unknown)
            }
            return BatchRun(
                outcome: .failed(results: [], failure: .connection, errorDescription: error.localizedDescription),
                plan: .autocommit,
                sessionState: .unknown
            )
        }
    }

    /// `GO 5` sends the batch five times and keeps every answer. A repetition that raised an error ends the
    /// repeating, as it ends the run.
    ///
    /// What the server printed is read after every repetition, because the driver hands over only what the latest
    /// request printed: read once at the end, a `GO 5` would report the fifth repetition's `PRINT` alone.
    private static func runBatch(
        _ prepared: PreparedBatch,
        driver: DatabaseDriver,
        failureOutput: ServerOutputBox
    ) async throws -> BatchOutput {
        var combined = QueryBatchResult.empty
        var printed = BatchPrintedOutput()
        for _ in 0..<max(prepared.batch.repeatCount, 1) {
            try Task.checkCancellation()
            let answer: QueryBatchResult
            do {
                answer = try await driver.answerBatch(
                    query: prepared.sentSQL,
                    rowCap: prepared.rowCap,
                    parameters: prepared.parameterValues
                )
            } catch {
                if !DatabaseCancellationDiagnosis.isCancellation(error) {
                    printed.append(await ServerOutputCapture.drain(driver))
                    failureOutput.store(printed.output)
                }
                throw error
            }
            printed.append(await ServerOutputCapture.drain(driver))
            combined = combined.followed(by: answer)
            guard answer.errors.isEmpty else { break }
        }
        var output = BatchOutput(
            resultSets: combined.resultSets,
            rowsAffected: combined.rowsAffected,
            errors: combined.errors,
            discardedResultSetCount: combined.discardedResultSetCount,
            executionTime: combined.executionTime,
            errorDescription: BatchErrorText.describe(combined.errors, batchStartLine: prepared.startLine)
        )
        output.serverOutput = printed.output
        return output
    }

    /// A failed batch ran, at least in part, and the server does not say how far, so every statement in it is
    /// treated as having run. That is the safe direction for the catalog: refreshing what did not change costs a
    /// fetch, missing what did leaves the sidebar wrong.
    private func postRanStatements(
        of prepared: [PreparedBatch],
        outcome: BatchStatementOutcome<BatchOutput>,
        connection: DatabaseConnection
    ) {
        let ranCount: Int
        switch outcome {
        case .completed, .cancelled:
            ranCount = prepared.count
        case .failed(let outputs, let failure, _):
            ranCount = failure.ranStatementCount(executedCount: outputs.count, totalCount: prepared.count)
        }
        let statements = prepared.prefix(ranCount).flatMap { $0.batch.statements.map(\.sql) }
        CatalogChangeService.post(
            .statementsRan(connectionId: connection.id, statements: statements, databaseType: connection.type)
        )
    }

    // MARK: - Results

    private func applyCompletedBatches(
        _ prepared: [PreparedBatch],
        outputs: [BatchOutput],
        parameters: [QueryParameter],
        tabId: UUID,
        claim: TabExecutionClaim,
        sessionNotice: String?
    ) {
        guard parent.tabExecution.settle(claim) else { return }
        parent.retireQueryTask(.claim(claim))

        let totalRowsAffected = outputs.reduce(0) { $0 + $1.rowsAffected }
        reportOperation(
            kind: .queryBatch,
            claim: claim,
            outcome: .succeeded(OperationSummary(rowsAffected: totalRowsAffected, statementCount: outputs.count))
        )
        recordBatchHistory(prepared, outputs: outputs, parameters: parameters, tabId: tabId, failedIndex: nil)
        presentMultiStatementResults(
            tabId: tabId,
            timing: PluginQueryTiming(total: outputs.reduce(0) { $0 + $1.executionTime }),
            totalRowsAffected: totalRowsAffected,
            newResultSets: batchResultSets(prepared, outputs: outputs, tabId: tabId),
            sessionNotice: sessionNotice
        )
    }

    private func keepStoppedBatches(
        _ prepared: [PreparedBatch],
        outputs: [BatchOutput],
        parameters: [QueryParameter],
        tabId: UUID,
        sessionNotice: String?
    ) {
        guard !outputs.isEmpty else { return }
        recordBatchHistory(prepared, outputs: outputs, parameters: parameters, tabId: tabId, failedIndex: nil)
        presentMultiStatementResults(
            tabId: tabId,
            timing: PluginQueryTiming(total: outputs.reduce(0) { $0 + $1.executionTime }),
            totalRowsAffected: outputs.reduce(0) { $0 + $1.rowsAffected },
            newResultSets: batchResultSets(prepared, outputs: outputs, tabId: tabId),
            sessionNotice: sessionNotice
        )
    }

    private func handleBatchFailure(
        _ context: MultiStatementFailureContext,
        prepared: [PreparedBatch],
        outputs: [BatchOutput],
        parameters: [QueryParameter],
        tabId: UUID,
        claim: TabExecutionClaim,
        failureOutput: PluginServerOutput
    ) {
        let report = context.report()
        let printed: PluginServerOutput
        if case .batch = context.failure, let failedOutput = outputs.last {
            printed = failedOutput.serverOutput
        } else {
            printed = failureOutput
        }
        let message = ServerOutputCapture.failureMessage(report.message, output: printed)
        let failedBatch = report.failedStatementIndex.flatMap { prepared.indices.contains($0) ? prepared[$0] : nil }

        let errorResult = ResultSet(label: report.resultLabel)
        errorResult.errorMessage = message
        errorResult.statementAnchor = failedBatch?.batch.anchor

        guard parent.tabExecution.settle(claim) else { return }
        parent.retireQueryTask(.claim(claim))
        reportOperation(kind: .queryBatch, claim: claim, outcome: .failed(reason: context.errorDescription))
        recordBatchHistory(
            prepared,
            outputs: outputs,
            parameters: parameters,
            tabId: tabId,
            failedIndex: report.failedStatementIndex,
            failureDescription: context.errorDescription
        )

        let timing = PluginQueryTiming(total: outputs.reduce(0) { $0 + $1.executionTime })
        parent.flushBufferToActiveResult(tabId: tabId, pinnedOnly: true)
        parent.tabManager.mutate(tabId: tabId) { tab in
            tab.execution.errorMessage = message
            tab.execution.errorQuery = report.failedSQL
            tab.execution.executionTime = timing.total
            tab.execution.lastExecutedAt = Date()
            tab.display.replaceUnpinnedResults(
                with: batchResultSets(prepared, outputs: outputs, tabId: tabId) + [errorResult]
            )
            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }
        }
        parent.seedBufferFromActiveResult(tabId: tabId)
        if parent.tabManager.selectedTabId == tabId {
            parent.toolbarState.isResultsCollapsed = false
            parent.toolbarState.recordQueryTiming(timing, for: tabId)
            parent.announceQueryError(report.message)
        }
    }

    /// One history entry per batch, because the batch is what ran. A failed batch is recorded as failed, with the
    /// error it raised.
    private func recordBatchHistory(
        _ prepared: [PreparedBatch],
        outputs: [BatchOutput],
        parameters: [QueryParameter],
        tabId: UUID,
        failedIndex: Int?,
        failureDescription: String? = nil
    ) {
        let connection = parent.connection
        for (index, entry) in prepared.enumerated() {
            let failed = index == failedIndex
            guard failed || index < outputs.count else { continue }
            let summary = index < outputs.count ? outputs[index].summary : BatchSummary(rowCount: 0, executionTime: 0)
            recordHistory(
                QueryHistoryRecordRequest(
                    query: entry.batch.sql.hasSuffix(";") ? entry.batch.sql : entry.batch.sql + ";",
                    connectionId: connection.id,
                    databaseName: historyDatabaseName(tabId: tabId),
                    databaseType: connection.type,
                    schemaName: historySchemaName(tabId: tabId),
                    source: .editor,
                    executionTime: summary.executionTime,
                    rowCount: failed ? -1 : summary.rowCount,
                    wasSuccessful: !failed,
                    errorMessage: failed ? failureDescription : nil
                )
            )
        }
    }

    /// Each batch's result sets in the order it returned them. A batch whose shape pins each result set to one of its
    /// queries names them after it and points back at it; any other batch numbers them and points at the batch.
    private func batchResultSets(
        _ prepared: [PreparedBatch],
        outputs: [BatchOutput],
        tabId: UUID
    ) -> [ResultSet] {
        let databaseType = parent.connection.type
        let grammar = parent.lexicalGrammar
        var resultSets: [ResultSet] = []
        for (entry, output) in zip(prepared, outputs) {
            let isPlainQuery = { (sql: String) in
                QueryExecutor.qualifiesForRowCap(sql: sql, tabType: .query, databaseType: databaseType)
            }
            let produced: [ResultSet]
            if BatchResultMapping.mapsToStatements(
                entry.batch,
                resultSetCount: output.resultSets.count,
                hasErrors: !output.errors.isEmpty,
                isPlainQuery: isPlainQuery
            ) {
                let queries = entry.batch.statements.filter { isPlainQuery($0.sql) }
                produced = zip(queries, output.resultSets).map { statement, result in
                    let replayable = entry.parameterValues == nil
                        && !BatchResultMapping.referencesLocalVariable(statement.sql, grammar: grammar)
                    return makeStatementResultSet(
                        result: result,
                        sql: statement.sql,
                        index: resultSets.count,
                        baseQuery: replayable ? statement.sql : nil,
                        tabId: tabId,
                        anchor: StatementAnchor(statement)
                    )
                }
            } else if output.resultSets.isEmpty {
                produced = output.errors.isEmpty
                    ? [countResultSet(output, anchor: entry.batch.anchor, index: resultSets.count)]
                    : []
            } else {
                produced = output.resultSets.enumerated().map { offset, result in
                    numberedResultSet(result, anchor: entry.batch.anchor, index: resultSets.count + offset)
                }
            }
            produced.last?.serverOutput = output.serverOutput
            resultSets += produced
        }
        return resultSets
    }

    private static func runNotice(
        outcome: BatchStatementOutcome<BatchOutput>,
        sessionState: PluginSessionTransactionState
    ) -> String? {
        let outputs: [BatchOutput]
        switch outcome {
        case .completed(let results), .cancelled(let results), .failed(let results, _, _):
            outputs = results
        }
        return BatchRunNotice.text(
            discardedResultSetCount: outputs.reduce(0) { $0 + $1.discardedResultSetCount },
            sessionState: sessionState
        )
    }

    private func numberedResultSet(_ result: QueryResult, anchor: StatementAnchor?, index: Int) -> ResultSet {
        let resultSet = ResultSet(
            label: ResultSet.label(tableName: nil, anchor: nil, index: index),
            tableRows: TableRows.from(
                queryRows: result.rows,
                columns: result.columns.map { String($0) },
                columnTypes: result.columnTypes,
                absentCells: result.absentCells
            )
        )
        resultSet.statementAnchor = anchor
        resultSet.executionTime = result.executionTime
        resultSet.rowsAffected = result.rowsAffected
        resultSet.statusMessage = result.statusMessage
        resultSet.isTruncated = result.isTruncated
        return resultSet
    }

    private func countResultSet(_ output: BatchOutput, anchor: StatementAnchor?, index: Int) -> ResultSet {
        let resultSet = ResultSet(label: ResultSet.label(tableName: nil, anchor: anchor, index: index))
        resultSet.statementAnchor = anchor
        resultSet.executionTime = output.executionTime
        resultSet.rowsAffected = output.rowsAffected
        return resultSet
    }
}
