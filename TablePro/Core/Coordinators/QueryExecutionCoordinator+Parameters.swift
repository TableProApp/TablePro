//
//  QueryExecutionCoordinator+Parameters.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

private let paramLog = Logger(subsystem: "com.TablePro", category: "QueryParameters")

/// One statement of a multi-statement run, resolved before the transaction opens so the
/// lease holds nothing but driver work.
/// Carries the driver-bound parameter values into the scoped-driver closure. The values are
/// handed to the driver and never touched again by the caller, which is what `[Any?]` hides.
private struct BoundParameterValues: @unchecked Sendable {
    let values: [Any?]
}

private struct PreparedStatement: @unchecked Sendable {
    let originalSQL: String
    let executableSQL: String
    let parameterValues: [Any?]?
    let rowCap: Int?
    let anchor: StatementAnchor?
}

/// What a multi-statement transaction left behind. The results travel out of the lease
/// so the tab, the history and the error sheet are updated after the driver is released.
private enum MultiStatementOutcome {
    case completed(results: [QueryResult])
    case failed(results: [QueryResult], failedSQL: String?, errorDescription: String)
    case cancelled
}

extension QueryExecutionCoordinator {
    func detectAndReconcileParameters(sql: String, existing: [QueryParameter]) -> [QueryParameter] {
        QueryExecutor.detectAndReconcileParameters(sql: sql, existing: existing)
    }

    func executeQueryWithParameters(
        _ sql: String,
        parameters: [QueryParameter],
        bypassRowLimit: Bool = false,
        anchor: StatementAnchor? = nil
    ) {
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
            originalSQL: sql,
            anchor: anchor
        )
    }

    /// The query runs on the tab's own database, not on wherever the connection's shared
    /// driver happens to be pointing.
    func executeQueryInternalParameterized(
        _ sql: String,
        parameters: [Any?],
        originalParameters: [QueryParameter],
        bypassRowLimit: Bool = false,
        originalSQL: String? = nil,
        anchor: StatementAnchor? = nil
    ) {
        guard let (selectedTab, index) = parent.tabManager.selectedTabAndIndex,
              !parent.tabExecution.isExecuting(selectedTab.id) else { return }

        guard let scope = parent.scope(for: selectedTab) else {
            parent.tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(localized: "Not connected to database")
            }
            return
        }

        if parent.currentQueryTask != nil {
            parent.currentQueryTask?.cancel()
            do {
                try DatabaseManager.shared.cancelRunningQuery(for: parent.connectionId)
            } catch {
                paramLog.warning("cancelQuery failed: \(error.localizedDescription, privacy: .public)")
            }
            parent.currentQueryTask = nil
        }

        parent.tabManager.mutate(at: index) { tab in
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
        }
        let tab = parent.tabManager.tabs[index]
        parent.toolbarState.setExecuting(true)

        if PluginManager.shared.supportsQueryProgress(for: parent.connection.type) {
            parent.installClickHouseProgressHandler()
        }

        let conn = parent.connection
        let tabId = parent.tabManager.tabs[index].id
        let claim = parent.tabExecution.claim(tabId)

        let rowCap = resolveRowCap(sql: sql, tabType: tab.tabType, bypassLimit: bypassRowLimit)
        let (tableName, isEditable) = parent.resolveTableEditability(tab: tab, sql: sql)

        let needsMetadataFetch: Bool
        if isEditable, let tableName {
            needsMetadataFetch = !isMetadataCached(tabId: tabId, tableName: tableName)
        } else {
            needsMetadataFetch = false
        }

        let boundValues = BoundParameterValues(values: parameters)
        let parameterizedTask = Task { [weak self, parent] in
            guard let self else { return }

            let schemaTask: Task<FetchedTableSchema, Error>?
            if needsMetadataFetch, let tableName {
                schemaTask = Task { try await QueryExecutor.fetchTableSchema(scope: scope, tableName: tableName) }
            } else {
                schemaTask = nil
            }

            do {
                let fetchResult = try await DatabaseManager.shared.withScopedDriver(
                    scope: scope,
                    route: DatabaseManager.shared.executionRoute(for: scope),
                    cancellation: .cancellableRead
                ) { [queryExecutor = parent.queryExecutor, boundValues] driver in
                    try await queryExecutor.executeQuery(
                        driver: driver,
                        sql: sql,
                        parameters: boundValues.values,
                        rowCap: rowCap
                    )
                }

                guard !Task.isCancelled else {
                    schemaTask?.cancel()
                    await parent.resetExecutionState(claim: claim, executionTime: fetchResult.executionTime)
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
                    claim: claim,
                    originalParameters: originalParameters,
                    nativeParameters: parameters,
                    originalSQL: originalSQL,
                    anchor: anchor
                )

                if isEditable, let tableName {
                    if needsMetadataFetch {
                        launchPhase2Work(
                            tableName: tableName,
                            tabId: tabId,
                            connectionType: conn.type,
                            schemaTask: schemaTask
                        )
                    } else {
                        launchPhase2Count(
                            tableName: tableName,
                            tabId: tabId,
                            connectionType: conn.type
                        )
                    }
                } else if !isEditable || tableName == nil {
                    await MainActor.run { [parent] in
                        parent.clearChangesIfCurrent(claim: claim)
                    }
                }
            } catch {
                schemaTask?.cancel()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard parent.tabExecution.settle(claim) else { return }
                    parent.tabManager.mutate(tabId: tabId) { tab in
                        tab.pagination.isLoadingMore = false
                    }
                    parent.retireQueryTask(for: claim)
                    if DatabaseCancellationDiagnosis.isCancellation(error) || Task.isCancelled {
                        parent.reportEndedExecutions([
                            EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
                        ])
                        return
                    }
                    handleQueryExecutionError(error, sql: sql, tabId: tabId, connection: conn)
                    reportOperation(kind: .query, claim: claim, outcome: .failed(reason: error.localizedDescription))
                }
            }
        }
        parent.installQueryTask(parameterizedTask, for: claim)
    }

    /// Every statement of the run shares one lease on the tab's database, so the
    /// transaction and its rollback reach the same handle. Result sets, history and the
    /// error sheet are produced afterwards, outside the lease.
    func executeMultipleStatementsWithParameters(
        _ statements: [SQLStatementScanner.ExecutableStatement],
        parameters: [QueryParameter],
        bypassRowLimit: Bool = false
    ) {
        guard let (selectedTab, index) = parent.tabManager.selectedTabAndIndex,
              !parent.tabExecution.isExecuting(selectedTab.id) else { return }

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

        guard let scope = parent.scope(for: selectedTab) else {
            parent.tabManager.mutate(at: index) {
                $0.execution.errorMessage = String(localized: "Not connected to database")
            }
            return
        }

        let style = PluginMetadataRegistry.shared.snapshot(
            forTypeId: parent.connection.type.pluginTypeId
        )?.parameterStyle ?? .questionMark

        parent.currentQueryTask?.cancel()

        parent.tabManager.mutate(at: index) { tab in
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
        }
        parent.toolbarState.setExecuting(true)

        let conn = parent.connection
        let tabId = parent.tabManager.tabs[index].id
        let claim = parent.tabExecution.claim(tabId)
        let totalCount = statements.count
        let tabType = parent.tabManager.tabs[index].tabType

        let transactionKind = OperationKind.worst(of: statements.map(\.sql), databaseType: conn.type)
        let prepared = statements.map { statement in
            prepareStatement(
                statement: statement,
                parameters: parameters,
                style: style,
                tabType: tabType,
                bypassRowLimit: bypassRowLimit
            )
        }

        let multiStatementTask = Task { [weak self, parent] in
            guard let self else { return }

            let outcome = await runMultiStatementTransaction(
                prepared: prepared,
                scope: scope,
                mode: transactionKind.declaresWrite ? .readWrite : .serverDefault,
                claim: claim
            )

            switch outcome {
            case .cancelled:
                guard parent.tabExecution.settle(claim) else { return }
                parent.retireQueryTask(for: claim)
                parent.reportEndedExecutions([
                    EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
                ])
            case .completed(let results):
                let resultSets = applyExecutedStatements(
                    prepared: prepared,
                    results: results,
                    parameters: parameters,
                    connection: conn,
                    tabId: tabId
                )
                applyMultiStatementResults(
                    tabId: tabId,
                    claim: claim,
                    cumulativeTime: results.reduce(0) { $0 + $1.executionTime },
                    totalRowsAffected: results.reduce(0) { $0 + $1.rowsAffected },
                    newResultSets: resultSets
                )
            case .failed(let results, let failedSQL, let errorDescription):
                var resultSets = applyExecutedStatements(
                    prepared: prepared,
                    results: results,
                    parameters: parameters,
                    connection: conn,
                    tabId: tabId
                )
                await handleMultiStatementError(
                    errorDescription: errorDescription,
                    connection: conn,
                    tabId: tabId,
                    claim: claim,
                    statements: statements,
                    executedCount: results.count,
                    totalCount: totalCount,
                    cumulativeTime: results.reduce(0) { $0 + $1.executionTime },
                    failedSQL: failedSQL,
                    resultSets: &resultSets
                )
            }
        }
        parent.installQueryTask(multiStatementTask, for: claim)
    }

    private func prepareStatement(
        statement: SQLStatementScanner.ExecutableStatement,
        parameters: [QueryParameter],
        style: ParameterStyle,
        tabType: TabType,
        bypassRowLimit: Bool
    ) -> PreparedStatement {
        let sql = statement.sql
        let parameterNames = parameters.isEmpty ? [] : SQLParameterExtractor.extractParameters(from: sql)
        let conversion = parameterNames.isEmpty
            ? nil
            : SQLParameterExtractor.convertToNativeStyle(sql: sql, parameters: parameters, style: style)
        let executableSQL = conversion?.sql ?? sql
        return PreparedStatement(
            originalSQL: sql,
            executableSQL: executableSQL,
            parameterValues: conversion?.values,
            rowCap: resolveRowCap(sql: executableSQL, tabType: tabType, bypassLimit: bypassRowLimit),
            anchor: StatementAnchor(statement)
        )
    }

    private func runMultiStatementTransaction(
        prepared: [PreparedStatement],
        scope: DatabaseScope,
        mode: PluginTransactionAccessMode,
        claim: TabExecutionClaim
    ) async -> MultiStatementOutcome {
        do {
            return try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: DatabaseManager.shared.executionRoute(for: scope),
                cancellation: .cancellableRead
            ) { driver in
                await self.runPreparedStatements(
                    prepared,
                    mode: mode,
                    claim: claim,
                    driver: driver
                )
            }
        } catch {
            if DatabaseCancellationDiagnosis.isCancellation(error) || Task.isCancelled {
                return .cancelled
            }
            return .failed(results: [], failedSQL: nil, errorDescription: error.localizedDescription)
        }
    }

    private func runPreparedStatements(
        _ prepared: [PreparedStatement],
        mode: PluginTransactionAccessMode,
        claim: TabExecutionClaim,
        driver: DatabaseDriver
    ) async -> MultiStatementOutcome {
        let useTransaction = driver.supportsTransactions
        if useTransaction {
            do {
                try await driver.beginTransaction(mode: mode)
            } catch {
                return .failed(results: [], failedSQL: nil, errorDescription: error.localizedDescription)
            }
        }

        var results: [QueryResult] = []
        for statement in prepared {
            guard !Task.isCancelled, parent.tabExecution.isCurrent(claim) else {
                await rollback(driver: driver, useTransaction: useTransaction)
                return .cancelled
            }
            do {
                results.append(try await executeStatement(
                    rowCap: statement.rowCap,
                    originalSQL: statement.executableSQL,
                    driver: driver,
                    parameters: statement.parameterValues
                ))
            } catch {
                await rollback(driver: driver, useTransaction: useTransaction)
                return .failed(
                    results: results,
                    failedSQL: statement.executableSQL,
                    errorDescription: error.localizedDescription
                )
            }
        }

        if useTransaction {
            do {
                try await driver.commitTransaction()
            } catch {
                await rollback(driver: driver, useTransaction: useTransaction)
                return .failed(results: results, failedSQL: nil, errorDescription: error.localizedDescription)
            }
        }
        return .completed(results: results)
    }

    private func rollback(driver: DatabaseDriver, useTransaction: Bool) async {
        guard useTransaction else { return }
        do {
            try await driver.rollbackTransaction()
        } catch {
            paramLog.error("Rollback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyExecutedStatements(
        prepared: [PreparedStatement],
        results: [QueryResult],
        parameters: [QueryParameter],
        connection: DatabaseConnection,
        tabId: UUID
    ) -> [ResultSet] {
        var resultSets: [ResultSet] = []
        for (index, pair) in zip(prepared, results).enumerated() {
            let (statement, result) = pair
            resultSets.append(makeStatementResultSet(
                result: result,
                sql: statement.originalSQL,
                index: index,
                baseQuery: statement.executableSQL,
                baseQueryParameterValues: statement.parameterValues?.map { $0 as? String },
                tabId: tabId,
                anchor: statement.anchor
            ))
            recordStatementHistory(
                sql: statement.originalSQL,
                result: result,
                connection: connection,
                databaseName: historyDatabaseName(tabId: tabId),
                parameterValues: statement.parameterValues == nil ? nil : parameters
            )
        }
        return resultSets
    }

    func applyParameterizedResult(
        tabId: UUID,
        fetchResult: QueryFetchResult,
        inlineMetadata: ParsedSchemaMetadata?,
        tableName: String?,
        isEditable: Bool,
        sql: String,
        connection: DatabaseConnection,
        claim: TabExecutionClaim,
        originalParameters: [QueryParameter],
        nativeParameters: [Any?],
        originalSQL: String? = nil,
        anchor: StatementAnchor? = nil
    ) async {
        await MainActor.run { [weak self] in
            guard let self else { return }
            guard parent.tabExecution.settle(claim) else { return }
            parent.retireQueryTask(for: claim)
            guard !Task.isCancelled else {
                parent.reportEndedExecutions([
                    EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
                ])
                return
            }
            if PluginManager.shared.supportsQueryProgress(for: parent.connection.type) {
                parent.clearClickHouseProgress()
            }
            parent.toolbarState.lastQueryDuration = fetchResult.executionTime
            reportOperation(
                kind: .query,
                claim: claim,
                outcome: .succeeded(
                    OperationSummary(
                        rowsReturned: fetchResult.rows.count,
                        rowsAffected: fetchResult.rowsAffected
                    )
                )
            )

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
                historySQL: originalSQL,
                anchor: anchor
            )

            let parameterValues = nativeParameters.map { $0 as? String }
            parent.tabManager.mutate(tabId: tabId) {
                $0.pagination.baseQueryParameterValues = parameterValues
                $0.display.activeResultSet?.baseQueryParameterValues = parameterValues
            }
        }
    }

    /// The transaction was already rolled back inside the lease that ran it, so this
    /// only reports the failure: resolving a driver here would reach a released handle.
    func handleMultiStatementError(
        errorDescription: String,
        connection: DatabaseConnection,
        tabId: UUID,
        claim: TabExecutionClaim,
        statements: [SQLStatementScanner.ExecutableStatement],
        executedCount: Int,
        totalCount: Int,
        cumulativeTime: TimeInterval,
        failedSQL: String?,
        resultSets: inout [ResultSet]
    ) async {
        /// A statement failure knows which statement it was: `executedCount` counts the ones that finished, so the
        /// next one is the one that threw. A commit failure knows no such thing. Every statement ran and the
        /// transaction failed on the way out, so numbering it `executedCount + 1` invented a statement past the end
        /// of the script and then blamed the last statement that had actually succeeded, which went to the error
        /// sheet, to Fix with AI, and into history a second time as a failure it never was.
        let failedStatement = executedCount < statements.count ? statements[executedCount] : nil
        let contextMsg: String
        let errorLabel: String
        if failedSQL != nil {
            let position = min(executedCount + 1, totalCount)
            contextMsg = String(
                format: String(localized: "Statement %1$d/%2$d failed: %3$@"),
                position, totalCount, errorDescription
            )
            errorLabel = String(format: String(localized: "Error %d"), position)
        } else {
            contextMsg = String(
                format: String(localized: "The transaction could not be committed: %@"),
                errorDescription
            )
            errorLabel = String(localized: "Error")
        }

        let errorRS = ResultSet(label: errorLabel)
        errorRS.errorMessage = contextMsg
        errorRS.statementAnchor = failedSQL == nil ? nil : failedStatement.map(StatementAnchor.init)
        resultSets.append(errorRS)

        let failedStatementSQL = failedSQL ?? failedStatement?.sql
        let capturedResultSets = resultSets
        await MainActor.run { [weak self] in
            guard let self else { return }
            guard parent.tabExecution.settle(claim) else { return }
            parent.retireQueryTask(for: claim)

            /// Below the settle gate for the same reason the success arm is: a superseded batch
            /// has its error dropped here, so announcing it would report on work the user has
            /// already navigated away from.
            reportOperation(kind: .queryBatch, claim: claim, outcome: .failed(reason: errorDescription))

            parent.flushBufferToActiveResult(tabId: tabId, pinnedOnly: true)
            parent.tabManager.mutate(tabId: tabId) { tab in
                tab.execution.errorMessage = contextMsg
                tab.execution.errorQuery = failedStatementSQL ?? ""
                tab.execution.executionTime = cumulativeTime
                tab.execution.lastExecutedAt = Date()

                tab.display.replaceUnpinnedResults(with: capturedResultSets)
                if tab.display.isResultsCollapsed {
                    tab.display.isResultsCollapsed = false
                }
            }
            parent.seedBufferFromActiveResult(tabId: tabId)
            if parent.tabManager.selectedTabId == tabId {
                parent.toolbarState.isResultsCollapsed = false
                parent.toolbarState.lastQueryDuration = cumulativeTime
                parent.announceQueryError(contextMsg)
            }

            /// Only a statement that actually failed goes to history. A commit failure would otherwise write the
            /// last statement that succeeded in a second time, marked as a failure.
            guard let rawSQL = failedStatementSQL else { return }
            let recordSQL = rawSQL.hasSuffix(";") ? rawSQL : rawSQL + ";"
            recordHistory(
                QueryHistoryRecordRequest(
                    query: recordSQL,
                    connectionId: connection.id,
                    databaseName: historyDatabaseName(tabId: tabId),
                    databaseType: connection.type,
                    schemaName: historySchemaName(tabId: tabId),
                    source: .editor,
                    executionTime: cumulativeTime,
                    rowCount: -1,
                    wasSuccessful: false,
                    errorMessage: errorDescription
                )
            )
        }
    }
}
