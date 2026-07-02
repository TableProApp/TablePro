//
//  QueryExecutionCoordinator+MultiStatement.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension QueryExecutionCoordinator {
    func executeMultipleStatements(_ statements: [String], bypassRowLimit: Bool = false) {
        executeMultipleStatementsWithParameters(statements, parameters: [], bypassRowLimit: bypassRowLimit)
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

    func makeStatementResultSet(
        result: QueryResult,
        sql: String,
        index: Int,
        baseQuery: String,
        baseQueryParameterValues: [String?]? = nil
    ) -> ResultSet {
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
        if !result.columns.isEmpty {
            resultSet.isTruncated = result.isTruncated
            resultSet.baseQuery = baseQuery
            resultSet.baseQueryParameterValues = baseQueryParameterValues
        }
        return resultSet
    }

    func recordStatementHistory(
        sql: String,
        result: QueryResult,
        connection: DatabaseConnection,
        parameterValues: [QueryParameter]? = nil
    ) {
        let historySQL = sql.hasSuffix(";") ? sql : sql + ";"
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
        newResultSets: [ResultSet]
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

            let activeResultSet = newResultSets.last
            if activeResultSet?.isTruncated == true {
                tab.pagination.hasMoreRows = true
                tab.pagination.isLoadingMore = false
            } else {
                tab.pagination.resetLoadMore()
            }
            tab.pagination.baseQueryForMore = activeResultSet?.baseQuery
            tab.pagination.baseQueryParameterValues = activeResultSet?.baseQueryParameterValues
        }
        parent.toolbarState.isResultsCollapsed = false

        if parent.tabManager.selectedTabId == tabId {
            parent.changeManager.clearChangesAndUndoHistory()
        }
    }
}
