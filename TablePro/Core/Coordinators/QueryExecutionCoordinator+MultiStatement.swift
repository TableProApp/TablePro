//
//  QueryExecutionCoordinator+MultiStatement.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

extension QueryExecutionCoordinator {
    func executeMultipleStatements(
        _ statements: [SQLStatementScanner.ExecutableStatement],
        bypassRowLimit: Bool = false
    ) {
        executeMultipleStatementsWithParameters(statements, parameters: [], bypassRowLimit: bypassRowLimit)
    }

    func executeStatement(
        rowCap: Int?,
        originalSQL: String,
        driver: DatabaseDriver,
        parameters: [Any?]? = nil
    ) async throws -> QueryResult {
        if rowCap != nil {
            if parameters == nil, let cap = rowCap, cap > 0,
               let bounded = try await driver.executeBoundedQuery(query: originalSQL, rowCap: cap) {
                return bounded
            }
            return try await driver.executeUserQuery(query: originalSQL, rowCap: rowCap, parameters: parameters)
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
        baseQuery: String?,
        baseQueryParameterValues: [String?]? = nil,
        tabId: UUID,
        anchor: StatementAnchor? = nil
    ) -> ResultSet {
        let tableName = parent.extractTableName(from: sql)
        let rows = TableRows.from(
            queryRows: result.rows,
            columns: result.columns.map { String($0) },
            columnTypes: result.columnTypes
        )
        let resultSet = ResultSet(
            label: ResultSet.label(tableName: tableName, anchor: anchor, index: index),
            tableRows: rows
        )
        resultSet.statementAnchor = anchor
        resultSet.executionTime = result.executionTime
        resultSet.rowsAffected = result.rowsAffected
        resultSet.statusMessage = result.statusMessage
        resultSet.serverOutput = result.serverOutput
        if !result.columns.isEmpty {
            resultSet.isTruncated = result.isTruncated
            resultSet.baseQuery = baseQuery
            resultSet.baseQueryParameterValues = baseQueryParameterValues
        }
        resultSet.origin = statementOrigin(sql: sql, tabId: tabId, producesRows: !result.columns.isEmpty)
        return resultSet
    }

    /// Each statement in a multi-statement run targets its own table, so each result carries its
    /// own identity. Nothing fetches key columns for these statements, so the origin says so and
    /// the result is read-only until something does. Inheriting the previous run's keys made an
    /// UPDATE match by another table's key names, and calling them "no keys" would hand the
    /// generator a whole-row WHERE that changes every duplicate row.
    private func statementOrigin(sql: String, tabId: UUID, producesRows: Bool) -> ResultOrigin? {
        guard let tab = parent.tabManager.tabs.first(where: { $0.id == tabId }) else { return nil }
        let resolved = parent.resolveTableEditability(tab: tab, sql: sql)
        return ResultOrigin(
            tableName: resolved.tableName,
            schemaName: tab.tableContext.schemaName,
            databaseName: historyDatabaseName(tabId: tabId),
            primaryKeyColumns: [],
            isEditable: resolved.isEditable && producesRows,
            isView: tab.tableContext.isView,
            objectType: tab.tableContext.objectType,
            keysResolved: false
        )
    }

    /// `unresolvedOutcome` is what a statement whose commit went unanswered carries. The statement
    /// itself succeeded, so its rows and its timing are real, but whether the server kept it is not
    /// something anything here can find out, and a plain success badge would say it did.
    func recordStatementHistory(
        sql: String,
        result: QueryResult,
        connection: DatabaseConnection,
        databaseName: String,
        parameterValues: [QueryParameter]? = nil,
        unresolvedOutcome: String? = nil
    ) {
        let historySQL = sql.hasSuffix(";") ? sql : sql + ";"
        recordHistory(
            QueryHistoryRecordRequest(
                query: historySQL,
                connectionId: connection.id,
                databaseName: databaseName,
                databaseType: connection.type,
                source: .editor,
                executionTime: result.executionTime,
                rowCount: result.rows.count,
                wasSuccessful: unresolvedOutcome == nil,
                errorMessage: unresolvedOutcome,
                timing: result.resolvedTiming
            )
        )
    }

    /// The settle gate, the task retirement, the history and the outcome notification belong to the
    /// caller: a stopped run has already settled its claim and reports a cancellation rather than a
    /// success, and still shows the results of the statements its plan could not take back.
    ///
    /// `sessionNotice` is the one thing a successful run may still have to say: a batch that joined
    /// a transaction the user already had open committed nothing, and nothing else in the window
    /// reports an open transaction.
    func presentMultiStatementResults(
        tabId: UUID,
        timing: PluginQueryTiming,
        totalRowsAffected: Int,
        newResultSets: [ResultSet],
        sessionNotice: String?
    ) {
        let cumulativeTime = timing.total
        parent.toolbarState.recordQueryTiming(timing, for: tabId)

        guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            return
        }

        let currentTab = parent.tabManager.tabs[idx]
        let activeResult = newResultSets.last
        let activeOrigin = activeResult?.origin

        parent.flushBufferToActiveResult(tabId: currentTab.id, pinnedOnly: true)
        parent.setActiveTableRows(activeResult?.tableRows ?? TableRows(), for: currentTab.id)

        parent.tabManager.mutate(at: idx) { tab in
            if tab.tabType == .query {
                tab.tableContext.tableName = activeOrigin?.tableName
                tab.tableContext.schemaName = activeOrigin?.schemaName
                tab.tableContext.primaryKeyColumns = activeOrigin?.primaryKeyColumns ?? []
                tab.tableContext.isEditable = activeOrigin?.isEditable ?? false
            } else if activeOrigin?.tableName == nil {
                tab.tableContext.isEditable = false
            }

            tab.schemaVersion += 1
            tab.execution.executionTime = cumulativeTime
            tab.execution.rowsAffected = totalRowsAffected
            tab.execution.lastExecutedAt = Date()
            tab.execution.errorMessage = nil
            tab.execution.statusMessage = sessionNotice

            tab.display.replaceUnpinnedResults(with: newResultSets)
            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }

            let activeResultSet = activeResult
            if activeResultSet?.isTruncated == true {
                tab.pagination.hasMoreRows = true
                tab.pagination.isLoadingMore = false
            } else {
                tab.pagination.resetLoadMore()
            }
            tab.pagination.setBaseQueryForMore(
                activeResultSet?.baseQuery,
                parameterValues: activeResultSet?.baseQueryParameterValues
            )
        }
        parent.toolbarState.isResultsCollapsed = false

        if parent.tabManager.selectedTabId == tabId {
            parent.changeManager.clearChangesAndUndoHistory()
        }
    }
}
