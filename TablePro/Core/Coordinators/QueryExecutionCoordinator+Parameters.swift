//
//  QueryExecutionCoordinator+Parameters.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

private let paramLog = Logger(subsystem: "com.TablePro", category: "QueryParameters")

extension QueryExecutionCoordinator {
    func detectAndReconcileParameters(sql: String, existing: [QueryParameter]) -> [QueryParameter] {
        QueryExecutor.detectAndReconcileParameters(sql: sql, existing: existing)
    }

    func executeQueryWithParameters(_ sql: String, parameters: [QueryParameter], bypassRowLimit: Bool = false) {
        guard let (_, index) = parent.tabManager.selectedTabAndIndex else { return }

        let missing = parameters.filter {
            !$0.isNull && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let firstMissing = missing.first {
            parent.tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(
                    format: String(localized: "Missing value for parameter: %@"),
                    ":\(firstMissing.name)"
                )
            }
            return
        }

        let style = PluginMetadataRegistry.shared.snapshot(
            forTypeId: parent.connection.type.pluginTypeId
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
            originalParameters: parameters,
            bypassRowLimit: bypassRowLimit,
            originalSQL: sql
        )
    }

    func executeQueryInternalParameterized(
        _ sql: String,
        parameters: [Any?],
        originalParameters: [QueryParameter],
        bypassRowLimit: Bool = false,
        originalSQL: String? = nil
    ) {
        guard let (selectedTab, index) = parent.tabManager.selectedTabAndIndex,
              !selectedTab.execution.isExecuting else { return }

        if parent.currentQueryTask != nil {
            parent.currentQueryTask?.cancel()
            do {
                try DatabaseManager.shared.driver(for: parent.connectionId)?.cancelQuery()
            } catch {
                paramLog.warning("cancelQuery failed: \(error.localizedDescription, privacy: .public)")
            }
            parent.currentQueryTask = nil
        }
        parent.queryGeneration += 1
        let capturedGeneration = parent.queryGeneration

        parent.tabManager.mutate(at: index) { tab in
            tab.execution.isExecuting = true
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
            tab.display.explainText = nil
            tab.display.explainPlan = nil
        }
        let tab = parent.tabManager.tabs[index]
        parent.toolbarState.setExecuting(true)

        if PluginManager.shared.supportsQueryProgress(for: parent.connection.type) {
            parent.installClickHouseProgressHandler()
        }

        let conn = parent.connection
        let tabId = parent.tabManager.tabs[index].id

        let plan = resolveExecutionPlan(sql: sql, tabType: tab.tabType, bypassLimit: bypassRowLimit)
        let (tableName, isEditable) = parent.resolveTableEditability(tab: tab, sql: sql)

        let needsMetadataFetch: Bool
        if isEditable, let tableName {
            needsMetadataFetch = !isMetadataCached(tabId: tabId, tableName: tableName)
        } else {
            needsMetadataFetch = false
        }
        let connId = parent.connectionId

        parent.currentQueryTask = Task { [weak self, parent] in
            guard let self else { return }

            let schemaTask: Task<FetchedTableSchema, Error>?
            if needsMetadataFetch, let tableName {
                schemaTask = Task { try await QueryExecutor.fetchTableSchema(connectionId: connId, tableName: tableName) }
            } else {
                schemaTask = nil
            }

            do {
                let fetchResult = try await parent.queryExecutor.executeQuery(
                    sql: plan.executedSQL,
                    parameters: parameters,
                    rowCap: plan.rowCap
                )

                guard !Task.isCancelled else {
                    schemaTask?.cancel()
                    await parent.resetExecutionState(tabId: tabId, executionTime: fetchResult.executionTime)
                    return
                }

                let inlineMeta = needsMetadataFetch
                    ? QueryExecutor.inlineMetadata(from: fetchResult.resultColumnMeta, columns: fetchResult.columns)
                    : nil

                await applyParameterizedResult(
                    tabId: tabId,
                    fetchResult: fetchResult,
                    inlineMetadata: inlineMeta,
                    tableName: tableName,
                    isEditable: isEditable,
                    sql: sql,
                    connection: conn,
                    capturedGeneration: capturedGeneration,
                    originalParameters: originalParameters,
                    nativeParameters: parameters,
                    originalSQL: originalSQL
                )

                if isEditable, let tableName {
                    if needsMetadataFetch {
                        launchPhase2Work(
                            tableName: tableName,
                            tabId: tabId,
                            capturedGeneration: capturedGeneration,
                            connectionType: conn.type,
                            schemaTask: schemaTask
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
                        guard capturedGeneration == parent.queryGeneration else { return }
                        guard !Task.isCancelled else { return }
                        parent.changeManager.clearChangesAndUndoHistory()
                    }
                }
            } catch {
                schemaTask?.cancel()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    parent.tabManager.mutate(tabId: tabId) { tab in
                        tab.execution.isExecuting = false
                        tab.pagination.isLoadingMore = false
                    }
                    parent.currentQueryTask = nil
                    parent.toolbarState.setExecuting(false)
                    if error is CancellationError || Task.isCancelled { return }
                    guard capturedGeneration == parent.queryGeneration else { return }
                    handleQueryExecutionError(error, sql: plan.executedSQL, tabId: tabId, connection: conn)
                }
            }
        }
    }

    func executeMultipleStatementsWithParameters(
        _ statements: [String],
        parameters: [QueryParameter],
        bypassRowLimit: Bool = false
    ) {
        guard let (selectedTab, index) = parent.tabManager.selectedTabAndIndex,
              !selectedTab.execution.isExecuting else { return }

        let missing = parameters.filter {
            !$0.isNull && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let firstMissing = missing.first {
            parent.tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(
                    format: String(localized: "Missing value for parameter: %@"),
                    ":\(firstMissing.name)"
                )
            }
            return
        }

        let style = PluginMetadataRegistry.shared.snapshot(
            forTypeId: parent.connection.type.pluginTypeId
        )?.parameterStyle ?? .questionMark

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
        let totalCount = statements.count

        let tabType = parent.tabManager.tabs[index].tabType

        parent.currentQueryTask = Task { [weak self, parent] in
            guard let self else { return }
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
                    parent.tabManager.mutate(tabId: tabId) { $0.execution.isExecuting = false }
                    parent.currentQueryTask = nil
                    parent.toolbarState.setExecuting(false)
                }

                for (stmtIndex, stmtSQL) in statements.enumerated() {
                    guard !Task.isCancelled else {
                        await rollbackAndResetState()
                        return
                    }
                    guard capturedGeneration == parent.queryGeneration else {
                        await rollbackAndResetState()
                        return
                    }

                    let stmtParamNames = parameters.isEmpty
                        ? []
                        : SQLParameterExtractor.extractParameters(from: stmtSQL)
                    let conversion = stmtParamNames.isEmpty
                        ? nil
                        : SQLParameterExtractor.convertToNativeStyle(sql: stmtSQL, parameters: parameters, style: style)
                    let statementSQL = conversion?.sql ?? stmtSQL

                    let plan = resolveExecutionPlan(sql: statementSQL, tabType: tabType, bypassLimit: bypassRowLimit)
                    failedSQL = plan.executedSQL
                    let result = try await executeStatement(
                        plan: plan,
                        originalSQL: statementSQL,
                        driver: driver,
                        parameters: conversion?.values
                    )
                    failedSQL = nil
                    executedCount = stmtIndex + 1
                    cumulativeTime += result.executionTime
                    totalRowsAffected += result.rowsAffected

                    if !result.columns.isEmpty {
                        lastSelectResult = result
                        lastSelectSQL = statementSQL
                    }

                    newResultSets.append(makeStatementResultSet(
                        result: result,
                        sql: stmtSQL,
                        index: stmtIndex,
                        baseQuery: statementSQL,
                        baseQueryParameterValues: conversion?.values.map { $0 as? String }
                    ))
                    recordStatementHistory(
                        sql: stmtSQL,
                        result: result,
                        connection: conn,
                        parameterValues: stmtParamNames.isEmpty ? nil : parameters
                    )
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

    func applyParameterizedResult(
        tabId: UUID,
        fetchResult: QueryFetchResult,
        inlineMetadata: ParsedSchemaMetadata?,
        tableName: String?,
        isEditable: Bool,
        sql: String,
        connection: DatabaseConnection,
        capturedGeneration: Int,
        originalParameters: [QueryParameter],
        nativeParameters: [Any?],
        originalSQL: String? = nil
    ) async {
        await MainActor.run { [weak self] in
            guard let self else { return }
            parent.currentQueryTask = nil
            if PluginManager.shared.supportsQueryProgress(for: parent.connection.type) {
                parent.clearClickHouseProgress()
            }
            parent.toolbarState.setExecuting(false)
            parent.toolbarState.lastQueryDuration = fetchResult.executionTime

            if capturedGeneration != parent.queryGeneration || Task.isCancelled {
                parent.tabManager.mutate(tabId: tabId) { $0.execution.isExecuting = false }
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
                metadata: inlineMetadata,
                hasSchema: false,
                sql: sql,
                connection: connection,
                isTruncated: fetchResult.isTruncated,
                queryParameterValues: originalParameters,
                historySQL: originalSQL
            )

            let parameterValues = nativeParameters.map { $0 as? String }
            parent.tabManager.mutate(tabId: tabId) {
                $0.pagination.baseQueryParameterValues = parameterValues
                $0.display.activeResultSet?.baseQueryParameterValues = parameterValues
            }
        }
    }

    func handleMultiStatementError(
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

        if capturedGeneration != parent.queryGeneration {
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
        errorRS.errorMessage = contextMsg
        resultSets.append(errorRS)

        let failedStatement = failedSQL ?? statements[min(executedCount, totalCount - 1)]
        let capturedResultSets = resultSets
        await MainActor.run { [weak self] in
            guard let self else { return }
            parent.currentQueryTask = nil
            parent.toolbarState.setExecuting(false)

            parent.tabManager.mutate(tabId: tabId) { tab in
                tab.execution.errorMessage = contextMsg
                tab.execution.errorQuery = failedStatement
                tab.execution.isExecuting = false
                tab.execution.executionTime = cumulativeTime

                tab.display.replaceUnpinnedResults(with: capturedResultSets)
            }

            let rawSQL = failedStatement
            let recordSQL = rawSQL.hasSuffix(";") ? rawSQL : rawSQL + ";"
            QueryHistoryManager.shared.recordQuery(
                query: recordSQL,
                connectionId: connection.id,
                databaseName: parent.activeDatabaseName,
                executionTime: cumulativeTime,
                rowCount: 0,
                wasSuccessful: false,
                errorMessage: error.localizedDescription
            )
        }
    }
}
