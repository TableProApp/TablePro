import Foundation
import os
import TableProPluginKit

private let paramLog = Logger(subsystem: "com.TablePro", category: "QueryParameters")

extension MainContentCoordinator {
    func detectAndReconcileParameters(sql: String, existing: [QueryParameter]) -> [QueryParameter] {
        QueryExecutor.detectAndReconcileParameters(sql: sql, existing: existing)
    }

    func executeQueryWithParameters(_ sql: String, parameters: [QueryParameter]) {
        guard let (_, index) = tabManager.selectedTabAndIndex else { return }

        let missing = parameters.filter {
            !$0.isNull && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let firstMissing = missing.first {
            tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(
                    format: String(localized: "Missing value for parameter: %@"),
                    ":\(firstMissing.name)"
                )
            }
            return
        }

        let style = PluginMetadataRegistry.shared.snapshot(
            forTypeId: connection.type.pluginTypeId
        )?.parameterStyle ?? .questionMark
        let conversion = SQLParameterExtractor.convertToNativeStyle(
            sql: sql,
            parameters: parameters,
            style: style
        )

        paramLog.info("Executing parameterized query: \(conversion.sql.prefix(100), privacy: .public) with \(conversion.values.count) parameters")

        executeQueryInternalParameterized(
            conversion.sql,
            parameters: conversion.values,
            originalParameters: parameters
        )
    }

    internal func executeQueryInternalParameterized(
        _ sql: String,
        parameters: [Any?],
        originalParameters: [QueryParameter]
    ) {
        guard let (selectedTab, index) = tabManager.selectedTabAndIndex,
              !selectedTab.execution.isExecuting else { return }

        if currentQueryTask != nil {
            currentQueryTask?.cancel()
            do {
                try DatabaseManager.shared.driver(for: connectionId)?.cancelQuery()
            } catch {
                Self.logger.warning("cancelQuery failed: \(error.localizedDescription, privacy: .public)")
            }
            currentQueryTask = nil
        }
        queryGeneration += 1
        let capturedGeneration = queryGeneration

        tabManager.mutate(at: index) { tab in
            tab.execution.isExecuting = true
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
            tab.display.explainText = nil
            tab.display.explainPlan = nil
        }
        let tab = tabManager.tabs[index]
        toolbarState.setExecuting(true)

        if PluginManager.shared.supportsQueryProgress(for: connection.type) {
            installClickHouseProgressHandler()
        }

        let conn = connection
        let tabId = tabManager.tabs[index].id

        let rowCap = resolveRowCap(sql: sql, tabType: tab.tabType)
        let (tableName, isEditable) = resolveTableEditability(tab: tab, sql: sql)

        let needsMetadataFetch: Bool
        if isEditable, let tableName {
            needsMetadataFetch = !isMetadataCached(tabId: tabId, tableName: tableName)
        } else {
            needsMetadataFetch = false
        }

        currentQueryTask = Task { [weak self] in
            guard let self else { return }

            do {
                let executionResult = try await queryExecutor.executeQuery(
                    sql: sql,
                    parameters: parameters,
                    rowCap: rowCap,
                    tableName: tableName,
                    fetchSchemaForTable: needsMetadataFetch
                )

                guard !Task.isCancelled else {
                    await resetExecutionState(
                        tabId: tabId,
                        executionTime: executionResult.fetchResult.executionTime
                    )
                    return
                }

                await applyParameterizedResult(
                    tabId: tabId,
                    fetchResult: executionResult.fetchResult,
                    schemaResult: executionResult.schemaResult,
                    tableName: tableName,
                    isEditable: isEditable,
                    sql: sql,
                    connection: conn,
                    capturedGeneration: capturedGeneration,
                    originalParameters: originalParameters,
                    nativeParameters: parameters
                )

                if isEditable, let tableName {
                    if needsMetadataFetch {
                        launchPhase2Work(
                            tableName: tableName,
                            tabId: tabId,
                            capturedGeneration: capturedGeneration,
                            connectionType: conn.type,
                            schemaResult: executionResult.schemaResult
                        )
                    } else {
                        launchPhase2Count(
                            tableName: tableName,
                            tabId: tabId,
                            capturedGeneration: capturedGeneration,
                            connectionType: conn.type
                        )
                    }
                } else if !isEditable || tableName == nil {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        guard capturedGeneration == queryGeneration else { return }
                        guard !Task.isCancelled else { return }
                        changeManager.clearChangesAndUndoHistory()
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    tabManager.mutate(tabId: tabId) { tab in
                        tab.execution.isExecuting = false
                        tab.pagination.isLoadingMore = false
                    }
                    currentQueryTask = nil
                    toolbarState.setExecuting(false)
                    guard capturedGeneration == queryGeneration else { return }
                    handleQueryExecutionError(error, sql: sql, tabId: tabId, connection: conn)
                }
            }
        }
    }

    func executeMultipleStatementsWithParameters(_ statements: [String], parameters: [QueryParameter]) {
        guard let (selectedTab, index) = tabManager.selectedTabAndIndex,
              !selectedTab.execution.isExecuting else { return }

        let missing = parameters.filter {
            !$0.isNull && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let firstMissing = missing.first {
            tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(
                    format: String(localized: "Missing value for parameter: %@"),
                    ":\(firstMissing.name)"
                )
            }
            return
        }

        let style = PluginMetadataRegistry.shared.snapshot(
            forTypeId: connection.type.pluginTypeId
        )?.parameterStyle ?? .questionMark

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
                            paramLog.error("Rollback failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    tabManager.mutate(tabId: tabId) { $0.execution.isExecuting = false }
                    currentQueryTask = nil
                    toolbarState.setExecuting(false)
                }

                for (stmtIndex, stmtSQL) in statements.enumerated() {
                    guard !Task.isCancelled else {
                        await rollbackAndResetState()
                        return
                    }
                    guard capturedGeneration == queryGeneration else {
                        await rollbackAndResetState()
                        return
                    }

                    failedSQL = stmtSQL
                    let stmtParamNames = SQLParameterExtractor.extractParameters(from: stmtSQL)

                    let result: QueryResult
                    if stmtParamNames.isEmpty {
                        result = try await driver.execute(query: stmtSQL)
                    } else {
                        let conversion = SQLParameterExtractor.convertToNativeStyle(
                            sql: stmtSQL,
                            parameters: parameters,
                            style: style
                        )
                        result = try await driver.executeParameterized(
                            query: conversion.sql,
                            parameters: conversion.values
                        )
                    }

                    failedSQL = nil
                    executedCount = stmtIndex + 1
                    cumulativeTime += result.executionTime
                    totalRowsAffected += result.rowsAffected

                    if !result.columns.isEmpty {
                        lastSelectResult = result
                        lastSelectSQL = stmtSQL
                    }

                    let stmtTableName = await MainActor.run { extractTableName(from: stmtSQL) }
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

                    let historySQL = stmtSQL.hasSuffix(";") ? stmtSQL : stmtSQL + ";"
                    await MainActor.run {
                        QueryHistoryManager.shared.recordQuery(
                            query: historySQL,
                            connectionId: conn.id,
                            databaseName: activeDatabaseName,
                            executionTime: result.executionTime,
                            rowCount: result.rows.count,
                            wasSuccessful: true,
                            errorMessage: nil,
                            parameterValues: stmtParamNames.isEmpty ? nil : parameters
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
                await handleMultiStatementError(
                    error: error,
                    connection: conn,
                    tabId: tabId,
                    capturedGeneration: capturedGeneration,
                    statements: statements,
                    executedCount: executedCount,
                    totalCount: totalCount,
                    cumulativeTime: cumulativeTime,
                    failedSQL: failedSQL,
                    resultSets: &newResultSets
                )
            }
        }
    }

    private func applyParameterizedResult(
        tabId: UUID,
        fetchResult: QueryFetchResult,
        schemaResult: SchemaResult?,
        tableName: String?,
        isEditable: Bool,
        sql: String,
        connection: DatabaseConnection,
        capturedGeneration: Int,
        originalParameters: [QueryParameter],
        nativeParameters: [Any?]
    ) async {
        let metadata = schemaResult.map { QueryExecutor.parseSchemaMetadata($0) }

        await MainActor.run { [weak self] in
            guard let self else { return }
            currentQueryTask = nil
            if PluginManager.shared.supportsQueryProgress(for: self.connection.type) {
                self.clearClickHouseProgress()
            }
            toolbarState.setExecuting(false)
            toolbarState.lastQueryDuration = fetchResult.executionTime

            if capturedGeneration != queryGeneration || Task.isCancelled {
                tabManager.mutate(tabId: tabId) { $0.execution.isExecuting = false }
                return
            }

            applyPhase1Result(
                tabId: tabId,
                columns: fetchResult.columns,
                columnTypes: fetchResult.columnTypes,
                rows: fetchResult.rows,
                executionTime: fetchResult.executionTime,
                rowsAffected: fetchResult.rowsAffected,
                statusMessage: fetchResult.statusMessage,
                tableName: tableName,
                isEditable: isEditable,
                metadata: metadata,
                hasSchema: schemaResult != nil,
                sql: sql,
                connection: connection,
                isTruncated: fetchResult.isTruncated,
                queryParameterValues: originalParameters
            )

            tabManager.mutate(tabId: tabId) {
                $0.pagination.baseQueryParameterValues = nativeParameters.map { $0 as? String }
            }
        }
    }

    private func handleMultiStatementError(
        error: Error,
        connection: DatabaseConnection,
        tabId: UUID,
        capturedGeneration: Int,
        statements: [String],
        executedCount: Int,
        totalCount: Int,
        cumulativeTime: TimeInterval,
        failedSQL: String?,
        resultSets: inout [ResultSet]
    ) async {
        if let driver = DatabaseManager.shared.driver(for: connection.id), driver.supportsTransactions {
            do {
                try await driver.rollbackTransaction()
            } catch {
                paramLog.error("Rollback failed: \(error.localizedDescription, privacy: .public)")
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
        resultSets.append(errorRS)

        let capturedResultSets = resultSets
        await MainActor.run { [weak self] in
            guard let self else { return }
            currentQueryTask = nil
            toolbarState.setExecuting(false)

            tabManager.mutate(tabId: tabId) { tab in
                tab.execution.errorMessage = contextMsg
                tab.execution.isExecuting = false
                tab.execution.executionTime = cumulativeTime

                let pinnedResults = tab.display.resultSets.filter(\.isPinned)
                tab.display.resultSets = pinnedResults + capturedResultSets
                tab.display.activeResultSetId = capturedResultSets.last?.id
            }

            let rawSQL = failedSQL ?? statements[min(executedCount, totalCount - 1)]
            let recordSQL = rawSQL.hasSuffix(";") ? rawSQL : rawSQL + ";"
            QueryHistoryManager.shared.recordQuery(
                query: recordSQL,
                connectionId: connection.id,
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
