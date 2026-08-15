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
        guard let request = explainRequest(variant: variant, statement: statement) else {
            tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(
                    localized: "EXPLAIN is not supported for this database type."
                )
            }
            return
        }

        let level = safeModeLevel
        guard level.appliesToAllQueries, level.requiresConfirmation else {
            executeExplain(request)
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
            executeExplain(request)
        }
    }

    // MARK: - Request

    private func explainStatement(in tab: QueryTab) -> String? {
        let fullQuery = tab.content.query

        let sql: String
        if tab.tabType == .table {
            sql = fullQuery
        } else if let firstCursor = cursorPositions.first, firstCursor.range.length > 0 {
            let nsQuery = fullQuery as NSString
            let clampedRange = NSIntersectionRange(
                firstCursor.range,
                NSRange(location: 0, length: nsQuery.length)
            )
            sql = nsQuery.substring(with: clampedRange).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            sql = SQLStatementScanner.statementAtCursor(
                in: fullQuery,
                cursorPosition: cursorPositions.first?.range.location ?? 0,
                dialect: sqlDialect
            )
        }

        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SQLStatementScanner.allStatements(in: trimmed, dialect: sqlDialect).first
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

    private func executeExplain(_ request: ExplainRequest) {
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

        currentQueryTask = Task { [weak self] in
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
                    currentQueryTask = nil
                    toolbarState.setExecuting(false)
                    guard tabExecution.isCurrent(claim) else { return }

                    tabManager.mutate(tabId: tabId) { tab in
                        tab.execution.executionTime = fetchResult.executionTime
                        tab.execution.rowsAffected = 0
                        tab.execution.statusMessage = nil
                        tab.execution.lastExecutedAt = Date()
                        tab.display.replaceUnpinnedResults(
                            with: [ExplainResultSetFactory.make(
                                rawText: rawText, plan: plan, sql: request.sql,
                                executionTime: fetchResult.executionTime
                            )]
                        )
                        if tab.display.isResultsCollapsed {
                            tab.display.isResultsCollapsed = false
                        }
                    }
                    toolbarState.isResultsCollapsed = false
                    tabExecution.settle(claim)

                    QueryHistoryManager.shared.recordQuery(
                        query: request.sql,
                        connectionId: conn.id,
                        databaseName: queryExecutionCoordinator.historyDatabaseName(tabId: tabId),
                        executionTime: fetchResult.executionTime,
                        rowCount: fetchResult.rows.count,
                        wasSuccessful: true,
                        errorMessage: nil,
                        parameterValues: nil
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    currentQueryTask = nil
                    toolbarState.setExecuting(false)
                    guard tabExecution.isCurrent(claim) else { return }

                    tabManager.mutate(tabId: tabId) { tab in
                        tab.execution.errorMessage = error.localizedDescription
                    }
                    tabExecution.settle(claim)

                    QueryHistoryManager.shared.recordQuery(
                        query: request.sql,
                        connectionId: conn.id,
                        databaseName: queryExecutionCoordinator.historyDatabaseName(tabId: tabId),
                        executionTime: 0,
                        rowCount: 0,
                        wasSuccessful: false,
                        errorMessage: error.localizedDescription,
                        parameterValues: nil
                    )
                }
            }
        }
    }
}
