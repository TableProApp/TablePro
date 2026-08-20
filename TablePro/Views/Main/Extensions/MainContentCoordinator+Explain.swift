//
//  MainContentCoordinator+Explain.swift
//  TablePro
//
//  The one path that runs EXPLAIN, whatever asked for it: the toolbar button, a variant picked
//  from its menu, or the Query menu item. Every one of them authorizes through the execution
//  gate and is fenced against a superseded result, the same way a normal query is.
//

import CodeEditSourceEditor
import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    func runExplain(variant: ExplainVariant? = nil) {
        guard let (tab, index) = tabManager.selectedTabAndIndex else { return }
        guard !tabExecution.isExecuting(tab.id) else {
            traceExecutionBlocked(tabId: tab.id, site: "runExplain")
            return
        }
        guard let statement = explainStatement(in: tab) else { return }
        let anchor = tab.tabType == .table ? nil : StatementAnchor(statement)
        guard let request = explainRequest(variant: variant, statement: statement.sql) else {
            tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(
                    localized: "EXPLAIN is not supported for this database type."
                )
            }
            return
        }

        let level = safeModeLevel
        guard level.appliesToAllQueries, level.requiresConfirmation else {
            run(request, anchor: anchor)
            return
        }

        Task {
            let decision = await ExecutionGateProvider.shared.authorize(
                OperationRequest(
                    connectionId: connectionId,
                    databaseType: connection.type,
                    sql: request.sql,
                    kind: .readQuery,
                    caller: .userInterface,
                    capabilities: .interactiveUser,
                    operationDescription: String(localized: "Execute Query")
                )
            )
            guard case .authorized = decision else { return }
            run(request, anchor: anchor)
        }
    }

    // MARK: - Request

    /// The statement EXPLAIN will describe, and where it sits in the tab's query.
    ///
    /// Resolved the same way a run resolves it, so the plan is anchored to the statement the reader would have run.
    /// A table tab's query is generated rather than typed, so its offset is meaningless and the caller drops it.
    private func explainStatement(in tab: QueryTab) -> SQLStatementScanner.ExecutableStatement? {
        let fullQuery = tab.content.query

        let sql: String
        let sourceOffset: Int
        if tab.tabType == .table {
            sql = fullQuery
            sourceOffset = 0
        } else if let firstCursor = cursorPositions.first, firstCursor.range.length > 0 {
            let nsQuery = fullQuery as NSString
            let clampedRange = NSIntersectionRange(
                firstCursor.range,
                NSRange(location: 0, length: nsQuery.length)
            )
            sql = nsQuery.substring(with: clampedRange)
            sourceOffset = clampedRange.location
        } else {
            let statement = SQLStatementScanner.locatedStatementAtCursor(
                in: fullQuery,
                cursorPosition: cursorPositions.first?.range.location ?? 0,
                dialect: sqlDialect
            )
            sql = statement.sql
            sourceOffset = statement.offset
        }

        return SQLStatementScanner
            .executableStatements(in: sql, dialect: sqlDialect)
            .first?
            .offset(by: sourceOffset)
    }

    private func explainRequest(variant: ExplainVariant?, statement: String) -> ExplainRequest? {
        if let request = ExplainRequest.make(
            variant: variant,
            declaredVariants: connection.type.explainVariants,
            databaseType: connection.type,
            statement: statement
        ) {
            return request
        }

        guard let adapter = services.databaseManager.driver(for: connectionId) as? PluginDriverAdapter,
              let fallbackSQL = adapter.buildExplainQuery(statement)
        else { return nil }

        return ExplainRequest.driverBuilt(sql: fallbackSQL, databaseType: connection.type)
    }

    // MARK: - Execution

    private func run(_ request: ExplainRequest, anchor: StatementAnchor?) {
        guard !request.isDriverBuilt else {
            executeQueryInternal(request.sql, anchor: anchor)
            return
        }
        executeExplain(request, anchor: anchor)
    }

    private func executeExplain(_ request: ExplainRequest, anchor: StatementAnchor?) {
        guard let (tab, index) = tabManager.selectedTabAndIndex else { return }
        guard let scope = scope(for: tab) else {
            tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(localized: "Not connected to database")
            }
            return
        }

        supersedeExecution(for: tab.id)
        let claim = tabExecution.claim(tab.id)
        let tabId = tab.id
        let conn = connection

        tabManager.mutate(at: index) { $0.execution.errorMessage = nil }
        toolbarState.setExecuting(true)

        let explainTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetchResult = try await services.databaseManager.withScopedDriver(
                    scope: scope,
                    route: services.databaseManager.executionRoute(for: scope),
                    cancellation: .cancellableRead
                ) { [queryExecutor] driver in
                    try await queryExecutor.executeQuery(
                        driver: driver, sql: request.sql, parameters: nil, rowCap: nil
                    )
                }
                let rawText = ExplainPlanTextFlattener.flatten(rows: fetchResult.rows)
                let plan = ExplainPlanParserRegistry.plan(from: rawText, format: request.format)

                await MainActor.run { [weak self] in
                    guard let self else { return }

                    // Every write below belongs to whoever owns the tab now. A superseded plan
                    // that cleared the spinner or nilled the task handle would be reporting on a
                    // query that is still running, so the gate comes before all of them.
                    guard tabExecution.settle(claim) else { return }
                    retireQueryTask(for: claim)
                    guard !Task.isCancelled else {
                        reportEndedExecutions([
                            EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
                        ])
                        return
                    }

                    reportOperation(
                        kind: .query,
                        claim: claim,
                        databaseName: operationDatabaseName(tabId: tabId),
                        outcome: .succeeded(OperationSummary())
                    )
                    flushBufferToActiveResult(tabId: tabId, pinnedOnly: true)
                    tabManager.mutate(tabId: tabId) { tab in
                        tab.execution.executionTime = fetchResult.executionTime
                        tab.execution.rowsAffected = 0
                        tab.execution.statusMessage = nil
                        tab.execution.lastExecutedAt = Date()
                        tab.pagination.resetLoadMore()
                        tab.display.replaceUnpinnedResults(
                            with: [ExplainResultSetFactory.make(
                                rawText: rawText,
                                plan: plan,
                                sql: request.sql,
                                executionTime: fetchResult.executionTime,
                                anchor: anchor
                            )]
                        )
                        if tab.display.isResultsCollapsed {
                            tab.display.isResultsCollapsed = false
                        }
                    }
                    seedBufferFromActiveResult(tabId: tabId)
                    toolbarState.isResultsCollapsed = false

                    recordHistory(
                        QueryHistoryRecordRequest(
                            query: request.sql,
                            connectionId: conn.id,
                            databaseName: queryExecutionCoordinator.historyDatabaseName(tabId: tabId),
                            databaseType: conn.type,
                            schemaName: queryExecutionCoordinator.historySchemaName(tabId: tabId),
                            source: .explain,
                            executionTime: fetchResult.executionTime,
                            rowCount: fetchResult.rows.count,
                            wasSuccessful: true
                        )
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard tabExecution.settle(claim) else { return }
                    retireQueryTask(for: claim)

                    // A cancelled EXPLAIN is not a failure the user needs told about, and it does
                    // not belong in history either.
                    if DatabaseCancellationDiagnosis.isCancellation(error) || Task.isCancelled {
                        reportEndedExecutions([
                            EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
                        ])
                        return
                    }

                    reportOperation(
                        kind: .query,
                        claim: claim,
                        databaseName: operationDatabaseName(tabId: tabId),
                        outcome: .failed(reason: error.localizedDescription)
                    )

                    tabManager.mutate(tabId: tabId) { tab in
                        tab.execution.errorMessage = error.localizedDescription
                        tab.execution.lastExecutedAt = Date()
                        if tab.display.isResultsCollapsed {
                            tab.display.isResultsCollapsed = false
                        }
                    }
                    if tabManager.selectedTabId == tabId {
                        toolbarState.isResultsCollapsed = false
                        announceQueryError(error.localizedDescription)
                    }

                    recordHistory(
                        QueryHistoryRecordRequest(
                            query: request.sql,
                            connectionId: conn.id,
                            databaseName: queryExecutionCoordinator.historyDatabaseName(tabId: tabId),
                            databaseType: conn.type,
                            schemaName: queryExecutionCoordinator.historySchemaName(tabId: tabId),
                            source: .explain,
                            executionTime: 0,
                            rowCount: -1,
                            wasSuccessful: false,
                            errorMessage: error.localizedDescription
                        )
                    )
                }
            }
        }
        installQueryTask(explainTask, for: claim)
    }
}
