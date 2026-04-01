//
//  MainContentCoordinator+MultiStatement.swift
//  TablePro
//
//  Multi-statement SQL execution support for MainContentCoordinator.
//  Executes each statement sequentially, stopping on first error.
//

import AppKit
import Foundation

extension MainContentCoordinator {
    // MARK: - Multi-Statement Execution

    /// Execute multiple SQL statements sequentially within a transaction,
    /// stopping on first error with automatic rollback.
    /// Displays results from the last SELECT statement (if any).
    func executeMultipleStatements(_ statements: [String]) {
        guard let index = tabManager.selectedTabIndex else { return }
        guard !tabManager.tabs[index].isExecuting else { return }

        currentQueryTask?.cancel()
        queryGeneration += 1
        let capturedGeneration = queryGeneration

        var tab = tabManager.tabs[index]
        tab.isExecuting = true
        tab.executionTime = nil
        tab.errorMessage = nil
        tabManager.tabs[index] = tab
        toolbarState.setExecuting(true)

        let conn = connection
        let tabId = tabManager.tabs[index].id
        let totalCount = statements.count

        currentQueryTask = Task {
            var cumulativeTime: TimeInterval = 0
            var lastSelectResult: QueryResult?
            var lastSelectSQL: String?
            var totalRowsAffected = 0
            var executedCount = 0
            var failedSQL: String?
            var newResultSets: [ResultSet] = []

            do {
                guard let driver = DatabaseManager.shared.driver(for: conn.id) else {
                    throw DatabaseError.notConnected
                }

                // Wrap in a transaction for atomicity
                try await driver.beginTransaction()

                /// Rollback transaction and reset executing state for early exits.
                @MainActor func rollbackAndResetState() async {
                    try? await driver.rollbackTransaction()
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        tabManager.tabs[idx].isExecuting = false
                    }
                    currentQueryTask = nil
                    toolbarState.setExecuting(false)
                }

                for (stmtIndex, sql) in statements.enumerated() {
                    guard !Task.isCancelled else {
                        await rollbackAndResetState()
                        return
                    }
                    guard capturedGeneration == queryGeneration else {
                        await rollbackAndResetState()
                        return
                    }

                    failedSQL = sql
                    let result = try await driver.execute(query: sql)
                    failedSQL = nil
                    executedCount = stmtIndex + 1
                    cumulativeTime += result.executionTime
                    totalRowsAffected += result.rowsAffected

                    // Keep the last result that has columns (i.e. a SELECT)
                    if !result.columns.isEmpty {
                        lastSelectResult = result
                        lastSelectSQL = sql
                    }

                    // Build a ResultSet for this statement
                    let stmtTableName = await MainActor.run { extractTableName(from: sql) }
                    let rs = ResultSet(label: stmtTableName ?? "Result \(stmtIndex + 1)")
                    // Deep copy to prevent C buffer retention issues
                    rs.rowBuffer = RowBuffer(
                        rows: result.rows.map { row in row.map { $0.map { String($0) } } },
                        columns: result.columns.map { String($0) },
                        columnTypes: result.columnTypes
                    )
                    rs.executionTime = result.executionTime
                    rs.rowsAffected = result.rowsAffected
                    rs.statusMessage = result.statusMessage
                    rs.tableName = stmtTableName
                    rs.resultVersion = 1
                    newResultSets.append(rs)

                    // Record with semicolon preserved for history/favorites
                    let historySQL = sql.hasSuffix(";") ? sql : sql + ";"
                    await MainActor.run {
                        QueryHistoryManager.shared.recordQuery(
                            query: historySQL,
                            connectionId: conn.id,
                            databaseName: conn.database,
                            executionTime: result.executionTime,
                            rowCount: result.rows.count,
                            wasSuccessful: true,
                            errorMessage: nil
                        )
                    }
                }

                // Commit the transaction
                try await driver.commitTransaction()

                // All statements succeeded — update tab with results
                await MainActor.run {
                    applyMultiStatementResults(
                        tabId: tabId,
                        capturedGeneration: capturedGeneration,
                        cumulativeTime: cumulativeTime,
                        totalRowsAffected: totalRowsAffected,
                        lastSelectResult: lastSelectResult,
                        lastSelectSQL: lastSelectSQL,
                        newResultSets: newResultSets
                    )
                }
            } catch {
                // Rollback on failure
                if let driver = DatabaseManager.shared.driver(for: conn.id) {
                    try? await driver.rollbackTransaction()
                }

                // Always reset isExecuting even if generation is stale —
                // skipping this leaves the tab permanently stuck in "executing" state.
                if capturedGeneration != queryGeneration {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                            tabManager.tabs[idx].isExecuting = false
                        }
                        currentQueryTask = nil
                        toolbarState.setExecuting(false)
                    }
                    return
                }

                let failedStmtIndex = executedCount + 1
                let contextMsg = "Statement \(failedStmtIndex)/\(totalCount) failed: "
                    + error.localizedDescription

                // Add an error ResultSet for the failed statement
                let errorRS = ResultSet(label: "Error \(failedStmtIndex)")
                errorRS.errorMessage = error.localizedDescription
                newResultSets.append(errorRS)

                await MainActor.run {
                    currentQueryTask = nil
                    toolbarState.setExecuting(false)

                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        var errTab = tabManager.tabs[idx]
                        errTab.errorMessage = contextMsg
                        errTab.isExecuting = false
                        errTab.executionTime = cumulativeTime

                        // Attach accumulated ResultSets (successful + error)
                        let pinnedResults = errTab.resultSets.filter(\.isPinned)
                        errTab.resultSets = pinnedResults + newResultSets
                        errTab.activeResultSetId = newResultSets.last?.id

                        tabManager.tabs[idx] = errTab
                    }

                    let rawSQL = failedSQL ?? statements[min(executedCount, totalCount - 1)]
                    let recordSQL = rawSQL.hasSuffix(";") ? rawSQL : rawSQL + ";"
                    QueryHistoryManager.shared.recordQuery(
                        query: recordSQL,
                        connectionId: conn.id,
                        databaseName: conn.database,
                        executionTime: cumulativeTime,
                        rowCount: 0,
                        wasSuccessful: false,
                        errorMessage: error.localizedDescription
                    )

                    AlertHelper.showErrorSheet(
                        title: String(localized: "Query Execution Failed"),
                        message: contextMsg,
                        window: contentWindow
                    )
                }
            }
        }
    }

    // MARK: - Multi-Statement Result Application

    private func applyMultiStatementResults(
        tabId: UUID,
        capturedGeneration: Int,
        cumulativeTime: TimeInterval,
        totalRowsAffected: Int,
        lastSelectResult: QueryResult?,
        lastSelectSQL: String?,
        newResultSets: [ResultSet]
    ) {
        currentQueryTask = nil
        toolbarState.setExecuting(false)
        toolbarState.lastQueryDuration = cumulativeTime

        // Always reset isExecuting even if generation is stale
        if capturedGeneration != queryGeneration {
            if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                tabManager.tabs[idx].isExecuting = false
            }
            return
        }
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            return
        }

        var updatedTab = tabManager.tabs[idx]

        if let selectResult = lastSelectResult {
            let safeColumns = selectResult.columns.map { String($0) }
            let safeColumnTypes = selectResult.columnTypes
            let safeRows = selectResult.rows.map { row in
                row.map { $0.map { String($0) } }
            }
            // For table tabs, preserve existing tableName instead of re-extracting
            // from SQL — extractTableName can fail on schema-qualified/quoted names
            let tableName: String?
            if updatedTab.tabType == .table, let existing = updatedTab.tableName {
                tableName = existing
            } else {
                tableName = lastSelectSQL.flatMap { extractTableName(from: $0) }
            }

            updatedTab.resultColumns = safeColumns
            updatedTab.columnTypes = safeColumnTypes
            updatedTab.resultRows = safeRows
            updatedTab.tableName = tableName
            updatedTab.isEditable = tableName != nil && updatedTab.isEditable
        } else {
            updatedTab.resultColumns = []
            updatedTab.columnTypes = []
            updatedTab.resultRows = []
            // Preserve tableName for table tabs even when no SELECT result
            if updatedTab.tabType != .table {
                updatedTab.tableName = nil
            }
            updatedTab.isEditable = false
        }

        updatedTab.resultVersion += 1
        updatedTab.executionTime = cumulativeTime
        updatedTab.rowsAffected = totalRowsAffected
        updatedTab.isExecuting = false
        updatedTab.lastExecutedAt = Date()
        updatedTab.errorMessage = nil

        let pinnedResults = updatedTab.resultSets.filter(\.isPinned)
        updatedTab.resultSets = pinnedResults + newResultSets
        updatedTab.activeResultSetId = newResultSets.last?.id
        if updatedTab.isResultsCollapsed {
            updatedTab.isResultsCollapsed = false
        }
        toolbarState.isResultsCollapsed = false

        tabManager.tabs[idx] = updatedTab

        if tabManager.selectedTabId == tabId {
            changeManager.clearChangesAndUndoHistory()
            changeManager.reloadVersion += 1
        }
    }
}
