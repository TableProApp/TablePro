import AppKit
import Foundation
import os

private let multiStatementLogger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator+MultiStatement")

extension MainContentCoordinator {
    // MARK: - Multi-Statement Execution

    func executeMultipleStatements(_ statements: [String]) {
        guard let index = tabManager.selectedTabIndex else { return }
        guard !tabManager.tabs[index].execution.isExecuting else { return }

        currentQueryTask?.cancel()
        queryGeneration += 1
        let capturedGeneration = queryGeneration

        tabManager.mutate(at: index) { tab in
            tab.execution.isExecuting = true
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
        }
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
                    tabManager.mutate(tabId: tabId) { $0.execution.isExecuting = false }
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

                    if !result.columns.isEmpty {
                        lastSelectResult = result
                        lastSelectSQL = sql
                    }

                    let stmtTableName = await MainActor.run { extractTableName(from: sql) }
                    let stmtRows = TableRows.from(
                        queryRows: result.rows.map { row in row.map { $0.map { String($0) } } },
                        columns: result.columns.map { String($0) },
                        columnTypes: result.columnTypes
                    )
                    let rs = ResultSet(label: stmtTableName ?? "Result \(stmtIndex + 1)", tableRows: stmtRows)
                    rs.executionTime = result.executionTime
                    rs.rowsAffected = result.rowsAffected
                    rs.statusMessage = result.statusMessage
                    rs.tableName = stmtTableName
                    newResultSets.append(rs)

                    let historySQL = sql.hasSuffix(";") ? sql : sql + ";"
                    await MainActor.run {
                        QueryHistoryManager.shared.recordQuery(
                            query: historySQL,
                            connectionId: conn.id,
                            databaseName: activeDatabaseName,
                            executionTime: result.executionTime,
                            rowCount: result.rows.count,
                            wasSuccessful: true,
                            errorMessage: nil
                        )
                    }
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
                        newResultSets: newResultSets
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

                if capturedGeneration != queryGeneration {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        tabManager.mutate(tabId: tabId) { $0.execution.isExecuting = false }
                        currentQueryTask = nil
                        toolbarState.setExecuting(false)
                    }
                    return
                }

                let failedStmtIndex = executedCount + 1
                let contextMsg = "Statement \(failedStmtIndex)/\(totalCount) failed: "
                    + error.localizedDescription

                let errorRS = ResultSet(label: "Error \(failedStmtIndex)")
                errorRS.errorMessage = error.localizedDescription
                newResultSets.append(errorRS)

                await MainActor.run {
                    currentQueryTask = nil
                    toolbarState.setExecuting(false)

                    tabManager.mutate(tabId: tabId) { tab in
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
                        databaseName: activeDatabaseName,
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

    internal func applyMultiStatementResults(
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

        if capturedGeneration != queryGeneration {
            tabManager.mutate(tabId: tabId) { $0.execution.isExecuting = false }
            return
        }
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            return
        }

        let currentTab = tabManager.tabs[idx]
        let resolvedTableName: String?
        if let selectResult = lastSelectResult {
            let safeColumns = selectResult.columns.map { String($0) }
            let safeColumnTypes = selectResult.columnTypes
            let safeRows = selectResult.rows.map { row in
                row.map { $0.map { String($0) } }
            }
            if currentTab.tabType == .table, let existing = currentTab.tableContext.tableName {
                resolvedTableName = existing
            } else {
                resolvedTableName = lastSelectSQL.flatMap { extractTableName(from: $0) }
            }

            setActiveTableRows(
                TableRows.from(queryRows: safeRows, columns: safeColumns, columnTypes: safeColumnTypes),
                for: currentTab.id
            )
        } else {
            resolvedTableName = nil
            setActiveTableRows(TableRows(), for: currentTab.id)
        }

        tabManager.mutate(at: idx) { tab in
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
        }
        toolbarState.isResultsCollapsed = false

        if tabManager.selectedTabId == tabId {
            changeManager.clearChangesAndUndoHistory()
        }
    }
}
