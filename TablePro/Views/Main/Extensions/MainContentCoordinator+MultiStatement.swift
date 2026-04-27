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

        var tab = tabManager.tabs[index]
        tab.execution.isExecuting = true
        tab.execution.executionTime = nil
        tab.execution.errorMessage = nil
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
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        tabManager.tabs[idx].execution.isExecuting = false
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

                    if !result.columns.isEmpty {
                        lastSelectResult = result
                        lastSelectSQL = sql
                    }

                    let stmtTableName = await MainActor.run { extractTableName(from: sql) }
                    let rs = ResultSet(label: stmtTableName ?? "Result \(stmtIndex + 1)")
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
                        if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                            tabManager.tabs[idx].execution.isExecuting = false
                        }
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

                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        var errTab = tabManager.tabs[idx]
                        errTab.execution.errorMessage = contextMsg
                        errTab.execution.isExecuting = false
                        errTab.execution.executionTime = cumulativeTime

                        let pinnedResults = errTab.display.resultSets.filter(\.isPinned)
                        errTab.display.resultSets = pinnedResults + newResultSets
                        errTab.display.activeResultSetId = newResultSets.last?.id

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
            if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                tabManager.tabs[idx].execution.isExecuting = false
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
            let tableName: String?
            if updatedTab.tabType == .table, let existing = updatedTab.tableContext.tableName {
                tableName = existing
            } else {
                tableName = lastSelectSQL.flatMap { extractTableName(from: $0) }
            }

            updatedTab.resultColumns = safeColumns
            updatedTab.columnTypes = safeColumnTypes
            updatedTab.resultRows = safeRows
            updatedTab.tableContext.tableName = tableName
            updatedTab.tableContext.isEditable = tableName != nil && updatedTab.tableContext.isEditable
        } else {
            updatedTab.resultColumns = []
            updatedTab.columnTypes = []
            updatedTab.resultRows = []
            if updatedTab.tabType != .table {
                updatedTab.tableContext.tableName = nil
            }
            updatedTab.tableContext.isEditable = false
        }

        updatedTab.resultVersion += 1
        updatedTab.execution.executionTime = cumulativeTime
        updatedTab.execution.rowsAffected = totalRowsAffected
        updatedTab.execution.isExecuting = false
        updatedTab.execution.lastExecutedAt = Date()
        updatedTab.execution.errorMessage = nil

        let pinnedResults = updatedTab.display.resultSets.filter(\.isPinned)
        updatedTab.display.resultSets = pinnedResults + newResultSets
        updatedTab.display.activeResultSetId = newResultSets.last?.id
        if updatedTab.display.isResultsCollapsed {
            updatedTab.display.isResultsCollapsed = false
        }
        toolbarState.isResultsCollapsed = false

        tabManager.tabs[idx] = updatedTab

        if tabManager.selectedTabId == tabId {
            changeManager.clearChangesAndUndoHistory()
            changeManager.reloadVersion += 1
        }
    }
}
