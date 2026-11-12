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
    let supersededResultSetCount: Int
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

/// One repetition's answer, carried through ``ServerOutputCapture`` so a batch reads its output where a statement does.
private struct PrintedBatchAnswer: CarriesServerOutput {
    let answer: QueryBatchResult
    var serverOutput: PluginServerOutput = .none
}

// Which query each batch's result sets belong to (nil: they are numbered), and their rows built off the main actor.
private struct BatchResultPlan {
    let queries: [[SQLStatementScanner.ExecutableStatement]?]
    let built: StatementRowsBuild
    // Over every result the batches produce, in order: each result set, and one count result per batch with none.
    let results: RunResultPlan
}

private struct BatchRun {
    let outcome: BatchStatementOutcome<BatchOutput>
    let plan: BatchTransactionPlan
    let sessionState: PluginSessionTransactionState
    let startState: PluginSessionTransactionState
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
        bypassRowLimit: Bool = false,
        onTab target: UUID? = nil
    ) {
        guard let (selectedTab, index) = parent.executionTab(target),
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
            postRanStatements(of: prepared, run: run, scope: scope, connection: conn)
            let plan = await batchResultPlan(prepared, outputs: Self.outputs(of: run.outcome), tabId: tabId)

            let sessionNotice = Self.runNotice(outcome: run.outcome, sessionState: run.sessionState)
            guard parent.tabExecution.settle(claim) || reportsUnknownCommitAfterStop(run.outcome, claim: claim) else {
                await keepBatchesAfterStop(
                    prepared, run: run, plan: plan, parameters: parameters, claim: claim, sessionNotice: sessionNotice
                )
                return
            }
            parent.retireQueryTask(.claim(claim))

            switch run.outcome {
            case .cancelled(let outputs):
                keepStoppedBatches(
                    prepared,
                    outputs: outputs,
                    parameters: parameters,
                    tabId: tabId,
                    sessionNotice: sessionNotice,
                    plan: plan,
                    presentsResults: true
                )
                parent.reportEndedExecutions([
                    EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
                ])
            case .completed(let outputs):
                applyCompletedBatches(
                    prepared, outputs: outputs, parameters: parameters,
                    tabId: tabId, claim: claim, sessionNotice: sessionNotice, plan: plan
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
                    failureOutput: run.failureOutput,
                    plan: plan
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
                && !SQLParameterExtractor.extractParameters(from: batch.sql, grammar: grammar).isEmpty
            let conversion = bindsParameters
                ? SQLParameterExtractor.convertToNativeStyle(
                    sql: batch.sql, parameters: parameters, style: style, grammar: grammar
                )
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
                let startState = await driver.heldSessionTransactionState()
                let plan = BatchTransactionPlan.autocommit.joining(startState)
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
                await DatabaseManager.shared.noteSessionStatements(
                    prepared.prefix(outcome.ranCount(of: prepared.count)).flatMap { $0.batch.statements.map(\.sql) },
                    ranOn: driver,
                    scope: scope
                )
                let sessionState = await driver.heldSessionTransactionState()
                return BatchRun(outcome: outcome, plan: plan, sessionState: sessionState, startState: startState)
            }
            run.failureOutput = failureOutput.output
            return run
        } catch {
            if DatabaseCancellationDiagnosis.isCancellation(error) || Task.isCancelled {
                return BatchRun(
                    outcome: .cancelled(results: []), plan: .autocommit, sessionState: .unknown, startState: .unknown
                )
            }
            return BatchRun(
                outcome: .failed(results: [], failure: .connection, errorDescription: error.localizedDescription),
                plan: .autocommit,
                sessionState: .unknown,
                startState: .unknown
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
        var earliest = QueryBatchResult.empty
        var latest = QueryBatchResult.empty
        var printed = BatchPrintedOutput()
        for _ in 0..<max(prepared.batch.repeatCount, 1) {
            try Task.checkCancellation()
            let repetitionFailure = ServerOutputBox()
            let printedAnswer: PrintedBatchAnswer
            do {
                printedAnswer = try await ServerOutputCapture.running(on: driver, failureOutput: repetitionFailure) {
                    PrintedBatchAnswer(answer: try await driver.answerBatch(
                        query: prepared.sentSQL,
                        rowCap: prepared.rowCap,
                        parameters: prepared.parameterValues
                    ))
                }
            } catch {
                if !DatabaseCancellationDiagnosis.isCancellation(error) {
                    printed.append(repetitionFailure.output)
                    failureOutput.store(printed.output)
                }
                throw error
            }
            printed.append(printedAnswer.serverOutput)
            let answer = printedAnswer.answer
            earliest = earliest.followed(by: answer)
            latest = latest.followedKeepingLatest(by: answer)
            guard answer.errors.isEmpty else { break }
        }
        // Once the driver read past result sets, the newest ones kept are not the batch's last.
        let combined = latest.discardedResultSetCount == 0 ? latest : earliest
        var output = BatchOutput(
            resultSets: combined.resultSets,
            rowsAffected: combined.rowsAffected,
            errors: combined.errors,
            discardedResultSetCount: combined.discardedResultSetCount,
            supersededResultSetCount: combined.supersededResultSetCount,
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
        run: BatchRun,
        scope: DatabaseScope,
        connection: DatabaseConnection
    ) {
        let ranCount: Int
        switch run.outcome {
        case .completed, .cancelled:
            ranCount = prepared.count
        case .failed(let outputs, let failure, _):
            ranCount = failure.ranStatementCount(executedCount: outputs.count, totalCount: prepared.count)
        }
        let statements = prepared.prefix(ranCount).flatMap { $0.batch.statements.map(\.sql) }
        CatalogChangeService.post(
            .statementsRan(connectionId: connection.id, statements: statements, databaseType: connection.type)
        )
        CatalogChangeService.post(.statementsSucceeded(SucceededStatements(
            scope: scope,
            databaseType: connection.type,
            statements: prepared.prefix(run.outcome.succeededCount).flatMap(\.batch.executedStatementTexts),
            commit: .run(
                startedIn: run.startState, endedIn: run.sessionState, plan: run.plan, completed: run.outcome.isCompleted
            )
        )))
    }

    // MARK: - Results

    private func applyCompletedBatches(
        _ prepared: [PreparedBatch],
        outputs: [BatchOutput],
        parameters: [QueryParameter],
        tabId: UUID,
        claim: TabExecutionClaim,
        sessionNotice: String?,
        plan: BatchResultPlan
    ) {
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
            newResultSets: batchResultSets(prepared, outputs: outputs, tabId: tabId, plan: plan),
            sessionNotice: sessionNotice
        )
    }

    // A Stop during a batch reads as one between batches: the completed ones are kept, with no error result.
    private func keepBatchesAfterStop(
        _ prepared: [PreparedBatch],
        run: BatchRun,
        plan: BatchResultPlan,
        parameters: [QueryParameter],
        claim: TabExecutionClaim,
        sessionNotice: String?
    ) async {
        let kept = run.outcome.keptAfterStop(plan: run.plan)
        guard !kept.isEmpty else { return }
        // A failed batch's own results were in the plan, so a run that drops it is planned again.
        let keptPlan = kept.count == Self.outputs(of: run.outcome).count
            ? plan
            : await batchResultPlan(prepared, outputs: kept, tabId: claim.tabId)
        let presentsResults = stoppedRunCanReplaceResults(onTab: claim.tabId)
        guard parent.tabExecution.settleStopped(claim, replacingContent: presentsResults) else { return }
        keepStoppedBatches(
            prepared,
            outputs: kept,
            parameters: parameters,
            tabId: claim.tabId,
            sessionNotice: sessionNotice,
            plan: keptPlan,
            presentsResults: presentsResults
        )
        parent.reportEndedExecutions([
            EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
        ])
    }

    private func keepStoppedBatches(
        _ prepared: [PreparedBatch],
        outputs: [BatchOutput],
        parameters: [QueryParameter],
        tabId: UUID,
        sessionNotice: String?,
        plan: BatchResultPlan,
        presentsResults: Bool
    ) {
        guard !outputs.isEmpty else { return }
        recordBatchHistory(prepared, outputs: outputs, parameters: parameters, tabId: tabId, failedIndex: nil)
        guard presentsResults else { return }
        presentMultiStatementResults(
            tabId: tabId,
            timing: PluginQueryTiming(total: outputs.reduce(0) { $0 + $1.executionTime }),
            totalRowsAffected: outputs.reduce(0) { $0 + $1.rowsAffected },
            newResultSets: batchResultSets(prepared, outputs: outputs, tabId: tabId, plan: plan),
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
        failureOutput: PluginServerOutput,
        plan: BatchResultPlan
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
        errorResult.failedQuery = report.failedSQL
        errorResult.statementAnchor = failedBatch?.batch.anchor

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
            // The Error result carries the failure, so the banner stays on it rather than over every other result.
            tab.execution.errorMessage = nil
            tab.execution.errorQuery = nil
            tab.execution.executionTime = timing.total
            tab.execution.lastExecutedAt = Date()
            tab.display.replaceUnpinnedResults(
                with: batchResultSets(prepared, outputs: outputs, tabId: tabId, plan: plan) + [errorResult]
            )
            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }
        }
        parent.seedBufferFromActiveResult(tabId: tabId)
        parent.dropParkedEdits(ofBackgroundTab: tabId)
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
        tabId: UUID,
        plan: BatchResultPlan
    ) -> [ResultSet] {
        let grammar = parent.lexicalGrammar
        let firstNumber = parent.tabManager.tabs.first { $0.id == tabId }?.display.pinnedResultCount ?? 0
        let reading = parent.tableNameReading
        let runPlan = plan.results
        var builtIndex = 0
        // Taken in the order `batchResultPlan` built them: batch by batch, each batch's result sets in order.
        func nextBuilt() -> StatementRows? {
            defer { builtIndex += 1 }
            return plan.built.statement(at: builtIndex, readBy: reading)
        }
        var own: [Int: ResultSet] = [:]
        var parts: [Int: RunSummaryPart] = [:]
        var candidate = 0
        // A result left out by the plan is never built; one the summary covers keeps only its counts and output.
        func place(_ result: QueryResult?, count output: BatchOutput? = nil, build: (Int) -> ResultSet) {
            defer { candidate += 1 }
            if let position = runPlan.position(ofStatement: candidate) {
                own[candidate] = build(firstNumber + position)
            } else if runPlan.summarizes(statement: candidate) {
                if let result {
                    parts[candidate] = RunSummaryPart(result)
                } else if let output {
                    parts[candidate] = RunSummaryPart(
                        rowsAffected: output.rowsAffected,
                        executionTime: output.executionTime,
                        serverOutput: .none,
                        statusMessage: nil
                    )
                }
            }
        }
        for ((entry, output), queries) in zip(zip(prepared, outputs), plan.queries) {
            candidate += output.supersededResultSetCount
            let firstCandidate = candidate
            if let queries {
                for (statement, result) in zip(queries, output.resultSets) {
                    let built = nextBuilt()
                    place(result) { index in
                        let replayable = entry.parameterValues == nil
                            && !BatchResultMapping.referencesLocalVariable(statement.sql, grammar: grammar)
                        return makeStatementResultSet(
                            result: result,
                            sql: statement.sql,
                            index: index,
                            baseQuery: replayable ? statement.sql : nil,
                            tabId: tabId,
                            anchor: StatementAnchor(statement),
                            built: built
                        )
                    }
                }
            } else if output.resultSets.isEmpty {
                if output.errors.isEmpty {
                    place(nil, count: output) { index in countResultSet(output, anchor: entry.batch.anchor, index: index) }
                }
            } else {
                for result in output.resultSets {
                    let built = nextBuilt()
                    place(result) { index in
                        numberedResultSet(result, anchor: entry.batch.anchor, index: index, tabId: tabId, built: built)
                    }
                }
            }
            // The batch's printed output belongs to its last result, wherever that result went.
            guard candidate > firstCandidate else { continue }
            let last = candidate - 1
            if let resultSet = own[last] {
                resultSet.serverOutput = output.serverOutput
            } else if let part = parts[last] {
                parts[last] = part.withServerOutput(output.serverOutput)
            }
        }
        let resultSets = runPlan.entries.compactMap { entry -> ResultSet? in
            switch entry {
            case .statement(let index):
                return own[index]
            case .summary(let indices):
                return makeRunSummaryResultSet(indices.compactMap { parts[$0] })
            }
        }
        appendDroppedNotice(of: runPlan, to: resultSets)
        return resultSets
    }

    // Decided once, before the settle: the mapping costs a classification per statement and the rows a pass each.
    private func batchResultPlan(_ prepared: [PreparedBatch], outputs: [BatchOutput], tabId: UUID) async -> BatchResultPlan {
        let databaseType = parent.connection.type
        let grammar = parent.lexicalGrammar
        let queries = zip(prepared, outputs).map { entry, output in
            Self.mappedQueries(of: entry, output: output, databaseType: databaseType, grammar: grammar)
        }
        // One entry per result in the order `batchResultSets` places them; a count result has no rows to build.
        var shapes: [Bool] = []
        var sources: [(sql: String?, result: QueryResult)] = []
        var sourceCandidates: [Int] = []
        for (mapped, output) in zip(queries, outputs) {
            if mapped == nil, output.resultSets.isEmpty {
                if output.errors.isEmpty {
                    shapes.append(false)
                }
                continue
            }
            // Result sets the batch let go still count toward the run's results, and are never shown.
            shapes += repeatElement(true, count: output.supersededResultSetCount)
            let pairs: [(sql: String?, result: QueryResult)] = mapped.map { mapped in
                zip(mapped, output.resultSets).map { (sql: $0.sql as String?, result: $1) }
            } ?? output.resultSets.map { (sql: nil, result: $0) }
            for pair in pairs {
                sourceCandidates.append(shapes.count)
                shapes.append(!pair.result.columns.isEmpty)
                sources.append(pair)
            }
        }
        let results = RunResultPlan(producesRows: shapes)
        let shown = zip(sources, sourceCandidates).map { source, candidate in
            results.showsRows(ofStatement: candidate) ? source : nil
        }
        return BatchResultPlan(queries: queries, built: await buildStatementRows(shown, tabId: tabId), results: results)
    }

    // The query each of a batch's result sets belongs to, or nil when the batch's shape does not pin them.
    private static func mappedQueries(
        of entry: PreparedBatch,
        output: BatchOutput,
        databaseType: DatabaseType,
        grammar: SQLLexicalGrammar
    ) -> [SQLStatementScanner.ExecutableStatement]? {
        let isPlainQuery = { (sql: String) in
            QueryExecutor.qualifiesForRowCap(sql: sql, tabType: .query, databaseType: databaseType)
        }
        guard output.supersededResultSetCount == 0, BatchResultMapping.mapsToStatements(
            entry.batch,
            resultSetCount: output.resultSets.count,
            hasErrors: !output.errors.isEmpty,
            grammar: grammar,
            isPlainQuery: isPlainQuery
        ) else { return nil }
        return entry.batch.statements.filter { isPlainQuery($0.sql) }
    }

    private static func outputs(of outcome: BatchStatementOutcome<BatchOutput>) -> [BatchOutput] {
        switch outcome {
        case .completed(let results), .cancelled(let results), .failed(let results, _, _):
            return results
        }
    }

    private static func runNotice(
        outcome: BatchStatementOutcome<BatchOutput>,
        sessionState: PluginSessionTransactionState
    ) -> String? {
        BatchRunNotice.text(
            discardedResultSetCount: outputs(of: outcome).reduce(0) { $0 + $1.discardedResultSetCount },
            sessionState: sessionState
        )
    }

    private func numberedResultSet(
        _ result: QueryResult,
        anchor: StatementAnchor?,
        index: Int,
        tabId: UUID,
        built: StatementRows?
    ) -> ResultSet {
        let resultSet = ResultSet(
            label: ResultSet.label(tableName: nil, anchor: nil, index: index),
            tableRows: statementTableRows(result, tableName: nil, tabId: tabId, built: built?.prepared)
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
