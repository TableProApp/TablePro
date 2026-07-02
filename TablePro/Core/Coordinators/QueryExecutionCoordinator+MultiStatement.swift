//
//  QueryExecutionCoordinator+MultiStatement.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProPluginKit

private let multiStatementLogger = Logger(subsystem: "com.TablePro", category: "MultiStatement")

extension QueryExecutionCoordinator {
    func executeMultipleStatements(_ statements: [String], bypassRowLimit: Bool = false) {
        guard let index = parent.tabManager.selectedTabIndex else { return }
        guard !parent.tabManager.tabs[index].execution.isExecuting else { return }

        parent.currentQueryTask?.cancel()
        parent.queryGeneration += 1
        let capturedGeneration = parent.queryGeneration

        parent.tabManager.mutate(at: index) { tab in
            tab.execution.isExecuting = true
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
        }
        parent.toolbarState.setExecuting(true)

        let conn = parent.connection
        let tabId = parent.tabManager.tabs[index].id
        let tabType = parent.tabManager.tabs[index].tabType
        let totalCount = statements.count

        parent.currentQueryTask = Task { [weak self, parent] in
            guard let self else { return }
            var cumulativeTime: TimeInterval = 0
            var lastSelectResult: QueryResult?
            var lastSelectSQL: String?
            var lastSelectTruncated = false
            var totalRowsAffected = 0
            var executedCount = 0
            var failedSQL: String?
            var newResultSets: [ResultSet] = []

            do {
                guard let driver = DatabaseManager.shared.driver(for: conn.id) else {
                    throw DatabaseError.notConnected
                }

                let useTransaction = driver.supportsTransactions

                if useTransaction {
                    try await driver.beginTransaction()
                }

                @MainActor func rollbackAndResetState() async {
                    if useTransaction {
                        do {
                            try await driver.rollbackTransaction()
                        } catch {
                            multiStatementLogger.error("Rollback failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    parent.tabManager.mutate(tabId: tabId) { $0.execution.isExecuting = false }
                    parent.currentQueryTask = nil
                    parent.toolbarState.setExecuting(false)
                }

                for (stmtIndex, sql) in statements.enumerated() {
                    guard !Task.isCancelled else {
                        await rollbackAndResetState()
                        return
                    }
                    guard capturedGeneration == parent.queryGeneration else {
                        await rollbackAndResetState()
                        return
                    }

                    let plan = resolveExecutionPlan(sql: sql, tabType: tabType, bypassLimit: bypassRowLimit)
                    failedSQL = plan.executedSQL
                    let result = try await executeStatement(plan: plan, originalSQL: sql, driver: driver)
                    failedSQL = nil
                    executedCount = stmtIndex + 1
                    cumulativeTime += result.executionTime
                    totalRowsAffected += result.rowsAffected

                    if !result.columns.isEmpty {
                        lastSelectResult = result
                        lastSelectSQL = sql
                        lastSelectTruncated = result.isTruncated
                    }

                    newResultSets.append(makeStatementResultSet(result: result, sql: sql, index: stmtIndex))
                    recordStatementHistory(executedSQL: plan.executedSQL, result: result, connection: conn)
                }

                if useTransaction {
                    try await driver.commitTransaction()
                }

                await MainActor.run {
                    applyMultiStatementResults(
                        tabId: tabId,
                        capturedGeneration: capturedGeneration,
                        cumulativeTime: cumulativeTime,
                        totalRowsAffected: totalRowsAffected,
                        lastSelectResult: lastSelectResult,
                        lastSelectSQL: lastSelectSQL,
                        newResultSets: newResultSets,
                        lastSelectTruncated: lastSelectTruncated
                    )
                }
            } catch {
                if let driver = DatabaseManager.shared.driver(for: conn.id), driver.supportsTransactions {
                    do {
                        try await driver.rollbackTransaction()
                    } catch {
                        multiStatementLogger.error("Rollback failed: \(error.localizedDescription, privacy: .public)")
                    }
                }

                if capturedGeneration != parent.queryGeneration
                    || error is CancellationError
                    || Task.isCancelled {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        parent.tabManager.mutate(tabId: tabId) { $0.execution.isExecuting = false }
                        parent.currentQueryTask = nil
                        parent.toolbarState.setExecuting(false)
                    }
                    return
                }

                let failedStmtIndex = executedCount + 1
                let contextMsg = "Statement \(failedStmtIndex)/\(totalCount) failed: "
                    + error.localizedDescription

                let errorRS = ResultSet(label: "Error \(failedStmtIndex)")
                errorRS.errorMessage = error.localizedDescription
                newResultSets.append(errorRS)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    parent.currentQueryTask = nil
                    parent.toolbarState.setExecuting(false)

                    parent.tabManager.mutate(tabId: tabId) { tab in
                        tab.execution.errorMessage = contextMsg
                        tab.execution.isExecuting = false
                        tab.execution.executionTime = cumulativeTime

                        let pinnedResults = tab.display.resultSets.filter(\.isPinned)
                        tab.display.resultSets = pinnedResults + newResultSets
                        tab.display.activeResultSetId = newResultSets.last?.id
                    }

                    let rawSQL = failedSQL ?? statements[min(executedCount, totalCount - 1)]
                    let recordSQL = rawSQL.hasSuffix(";") ? rawSQL : rawSQL + ";"
                    QueryHistoryManager.shared.recordQuery(
                        query: recordSQL,
                        connectionId: conn.id,
                        databaseName: parent.activeDatabaseName,
                        executionTime: cumulativeTime,
                        rowCount: 0,
                        wasSuccessful: false,
                        errorMessage: error.localizedDescription
                    )

                    AlertHelper.showErrorSheet(
                        title: String(localized: "Query Execution Failed"),
                        message: contextMsg,
                        window: parent.contentWindow
                    )
                }
            }
        }
    }

    func executeStatement(
        plan: QueryLimitPlan,
        originalSQL: String,
        driver: DatabaseDriver,
        parameters: [Any?]? = nil
    ) async throws -> QueryResult {
        if plan.rowCap != nil {
            return try await driver.executeUserQuery(query: plan.executedSQL, rowCap: plan.rowCap, parameters: parameters)
        }
        if let parameters {
            return try await driver.executeParameterized(query: originalSQL, parameters: parameters)
        }
        return try await driver.execute(query: originalSQL)
    }

    func makeStatementResultSet(result: QueryResult, sql: String, index: Int) -> ResultSet {
        let tableName = parent.extractTableName(from: sql)
        let rows = TableRows.from(
            queryRows: result.rows,
            columns: result.columns.map { String($0) },
            columnTypes: result.columnTypes
        )
        let resultSet = ResultSet(label: tableName ?? "Result \(index + 1)", tableRows: rows)
        resultSet.executionTime = result.executionTime
        resultSet.rowsAffected = result.rowsAffected
        resultSet.statusMessage = result.statusMessage
        resultSet.tableName = tableName
        return resultSet
    }

    func recordStatementHistory(
        executedSQL: String,
        result: QueryResult,
        connection: DatabaseConnection,
        parameterValues: [QueryParameter]? = nil
    ) {
        let historySQL = executedSQL.hasSuffix(";") ? executedSQL : executedSQL + ";"
        QueryHistoryManager.shared.recordQuery(
            query: historySQL,
            connectionId: connection.id,
            databaseName: parent.activeDatabaseName,
            executionTime: result.executionTime,
            rowCount: result.rows.count,
            wasSuccessful: true,
            errorMessage: nil,
            parameterValues: parameterValues
        )
    }

    func applyMultiStatementResults(
        tabId: UUID,
        capturedGeneration: Int,
        cumulativeTime: TimeInterval,
        totalRowsAffected: Int,
        lastSelectResult: QueryResult?,
        lastSelectSQL: String?,
        newResultSets: [ResultSet],
        lastSelectTruncated: Bool = false,
        lastSelectParameterValues: [String?]? = nil
    ) {
        parent.currentQueryTask = nil
        parent.toolbarState.setExecuting(false)
        parent.toolbarState.lastQueryDuration = cumulativeTime

        if capturedGeneration != parent.queryGeneration {
            parent.tabManager.mutate(tabId: tabId) { $0.execution.isExecuting = false }
            return
        }
        guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            return
        }

        let currentTab = parent.tabManager.tabs[idx]
        let resolvedTableName: String?
        if let selectResult = lastSelectResult {
            let safeColumns = selectResult.columns.map { String($0) }
            let safeColumnTypes = selectResult.columnTypes
            let safeRows = selectResult.rows
            if currentTab.tabType == .table, let existing = currentTab.tableContext.tableName {
                resolvedTableName = existing
            } else {
                resolvedTableName = lastSelectSQL.flatMap { parent.extractTableName(from: $0) }
            }

            parent.setActiveTableRows(
                TableRows.from(queryRows: safeRows, columns: safeColumns, columnTypes: safeColumnTypes),
                for: currentTab.id
            )
        } else {
            resolvedTableName = nil
            parent.setActiveTableRows(TableRows(), for: currentTab.id)
        }

        parent.tabManager.mutate(at: idx) { tab in
            if lastSelectResult != nil {
                tab.tableContext.tableName = resolvedTableName
                tab.tableContext.isEditable = resolvedTableName != nil && tab.tableContext.isEditable
            } else {
                if tab.tabType != .table {
                    tab.tableContext.tableName = nil
                }
                tab.tableContext.isEditable = false
            }

            tab.schemaVersion += 1
            tab.execution.executionTime = cumulativeTime
            tab.execution.rowsAffected = totalRowsAffected
            tab.execution.isExecuting = false
            tab.execution.lastExecutedAt = Date()
            tab.execution.errorMessage = nil

            let pinnedResults = tab.display.resultSets.filter(\.isPinned)
            tab.display.resultSets = pinnedResults + newResultSets
            tab.display.activeResultSetId = newResultSets.last?.id
            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }

            if lastSelectTruncated {
                tab.pagination.hasMoreRows = true
                tab.pagination.isLoadingMore = false
            } else {
                tab.pagination.resetLoadMore()
            }
            tab.pagination.baseQueryForMore = lastSelectSQL
            tab.pagination.baseQueryParameterValues = lastSelectParameterValues
        }
        parent.toolbarState.isResultsCollapsed = false

        if parent.tabManager.selectedTabId == tabId {
            parent.changeManager.clearChangesAndUndoHistory()
        }
    }
}
