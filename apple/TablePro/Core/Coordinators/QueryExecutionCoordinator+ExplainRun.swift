//
//  QueryExecutionCoordinator+ExplainRun.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension QueryExecutionCoordinator {
    func executeExplain(_ request: ExplainRequest, anchor: StatementAnchor?, onTab tabId: UUID) {
        guard let run = TabRun.begin(onTab: tabId, in: parent) else { return }
        let conn = run.connection
        let safeModeIsReadOnly = parent.runsAtReadOnly
        // EXPLAIN ANALYZE and an actual plan run the statement, so Manual Commit holds them as it would the write.
        let ranWrite = request.operationKind(databaseType: conn.type).declaresWrite
        let held = parent.manualCommitRun(skipped: !ranWrite)
        let failureOutput = ServerOutputBox()

        run.launch { [weak self] run in
            guard let self else { return }
            let parent = self.parent
            do {
                let fetchResult = try await parent.services.databaseManager.withScopedDriver(
                    scope: run.scope,
                    route: parent.services.databaseManager.executionRoute(for: run.scope),
                    cancellation: .cancellableRead(run.lease), sessionWork: .statements
                ) { [queryExecutor = parent.queryExecutor] driver in
                    try await held.running([request.gatedSQL(databaseType: conn.type)], on: driver) {
                        try await ServerOutputCapture.running(on: driver, failureOutput: failureOutput) { () async throws -> QueryFetchResult in
                            if let step = request.driverStep {
                                return try await QueryExecutor.fetchExplainPlan(
                                    driver: driver, statement: request.subjectSQL, variantId: step.variantId
                                )
                            }
                            return try await queryExecutor.executeQuery(
                                driver: driver, sql: request.sql, parameters: nil, rowCap: nil, safeModeIsReadOnly: safeModeIsReadOnly
                            )
                        }
                    }
                }
                if ranWrite { MainContentCoordinator.postStatementRan(request.subjectSQL, on: conn) }
                let rawText = ExplainPlanTextFlattener.flatten(rows: fetchResult.rows)

                guard run.settle() else { return }
                guard !Task.isCancelled else {
                    run.reportCancelled()
                    return
                }
                run.report(.query, .succeeded(OperationSummary()))
                installExplainPlan(
                    ExplainResultRouter.RoutedPlan(
                        rawText: rawText,
                        plan: ExplainPlanParserRegistry.plan(from: rawText, format: request.format),
                        format: request.format,
                        variantKey: request.variantKey,
                        subjectSQL: request.subjectSQL
                    ),
                    onTab: tabId,
                    executionTime: fetchResult.executionTime,
                    rowCount: fetchResult.rows.count,
                    resultSQL: request.replayableSQL,
                    historySQL: request.sql,
                    connection: conn,
                    anchor: anchor,
                    serverOutput: fetchResult.serverOutput
                )
            } catch {
                if ranWrite { MainContentCoordinator.postStatementRan(request.subjectSQL, on: conn) }
                parent.finishFailedQuery(
                    error,
                    tabId: tabId,
                    sql: request.sql,
                    connection: conn,
                    claim: run.claim,
                    isAutoLoad: false,
                    trigger: .userInitiated,
                    traceToken: nil,
                    serverOutput: failureOutput.output,
                    historySource: .explain
                )
            }
        }
    }

    // The one place a plan lands, from a typed EXPLAIN or the Explain button: same result, plan capture and history row.
    func installExplainPlan(
        _ routed: ExplainResultRouter.RoutedPlan,
        onTab tabId: UUID,
        executionTime: TimeInterval,
        rowCount: Int,
        resultSQL: String?,
        historySQL: String,
        connection conn: DatabaseConnection,
        queryParameterValues: [QueryParameter]? = nil,
        anchor: StatementAnchor? = nil,
        timing: PluginQueryTiming? = nil,
        serverOutput: PluginServerOutput
    ) {
        let databaseName = historyDatabaseName(tabId: tabId)
        let schemaName = historySchemaName(tabId: tabId)
        let historyId = UUID()
        let captured = QueryPlanCaptureBuilder.make(
            subjectSQL: routed.subjectSQL,
            rawPlan: routed.rawText,
            format: routed.format,
            variantKey: routed.variantKey,
            scope: QueryPlanScope(
                connectionId: conn.id,
                databaseType: conn.type,
                databaseName: databaseName,
                schemaName: schemaName
            ),
            executionTime: executionTime,
            capturedAt: Date(),
            historyId: historyId,
            queryParameters: queryParameterValues
        )
        parent.flushBufferToActiveResult(tabId: tabId, pinnedOnly: true)
        parent.tabManager.mutate(tabId: tabId) { tab in
            tab.execution.executionTime = executionTime
            tab.execution.rowsAffected = 0
            tab.execution.statusMessage = nil
            tab.execution.lastExecutedAt = Date()
            tab.pagination.resetLoadMore()
            tab.display.replaceUnpinnedResults(
                with: [ExplainResultSetFactory.make(
                    rawText: routed.rawText,
                    plan: routed.plan,
                    sql: resultSQL,
                    executionTime: executionTime,
                    anchor: anchor,
                    planContext: captured.context,
                    serverOutput: serverOutput
                )]
            )
            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }
        }
        parent.seedBufferFromActiveResult(tabId: tabId)
        parent.dropEdits(ofReplacedResultIn: tabId)
        if parent.tabManager.selectedTabId == tabId {
            parent.toolbarState.isResultsCollapsed = false
        }

        recordRunHistory(
            RunHistoryEntry(
                id: historyId,
                query: historySQL,
                source: .explain,
                executionTime: executionTime,
                rowCount: rowCount,
                planCapture: captured.capture,
                timing: timing
            ),
            tabId: tabId
        )
    }
}
