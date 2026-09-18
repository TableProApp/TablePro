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

/// What one multi-statement run left behind, and the plan it actually ran under.
///
/// The plan is decided twice: from the statement text before any driver is leased, and again inside
/// the lease, where the driver can say what the session is already holding. Only the second answer
/// ran, so the failure banner and the status line are written from it.
private struct MultiStatementRun {
    let outcome: BatchStatementOutcome
    let plan: BatchTransactionPlan
    let sessionState: PluginSessionTransactionState
}

private struct PreparedStatement: @unchecked Sendable {
    let originalSQL: String
    let executableSQL: String
    /// `executableSQL` with the LIMIT an engine that caps its rows is always sent. Kept apart
    /// because Fetch All re-runs `executableSQL`, and re-running the limited text would fetch the
    /// same trimmed rows again.
    let sentSQL: String
    let parameterValues: [Any?]?
    let rowCap: Int?
    let anchor: StatementAnchor?
    /// Whether this is the script's own `COMMIT`, read from the text before the lease is taken so
    /// the run never lexes inside it.
    let isCommitPoint: Bool
}

/// What a run has to write into query history, held together so the recording can happen below the
/// settle gate rather than beside the result sets.
///
/// A batch that was stopped, or superseded by a navigation, has its results dropped there. History
/// used to be written above the gate, so a stopped run recorded every statement as successful while
/// the tab reported it as stopped, which is not what the single-statement path does.
private struct ExecutedStatementHistory {
    let prepared: [PreparedStatement]
    let results: [QueryResult]
    let parameters: [QueryParameter]
    let connection: DatabaseConnection
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
            for: parent.connection.type
        )?.parameterStyle ?? .questionMark
        let conversion = SQLParameterExtractor.convertToNativeStyle(
            sql: sql,
            parameters: parameters,
            style: style
        )

        paramLog.info("Executing parameterized query: \(conversion.sql.prefix(100), privacy: .private) with \(conversion.values.count) parameters")

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

        parent.tabManager.mutate(at: index) { tab in
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
        }
        let tab = parent.tabManager.tabs[index]

        let conn = parent.connection
        let tabId = parent.tabManager.tabs[index].id
        let (claim, lease) = parent.beginTabExecution(for: tabId)

        let statement = resolveStatement(sql: sql, tabType: tab.tabType, bypassLimit: bypassRowLimit)
        let rowCap = statement.rowCap
        let (tableName, isEditable) = parent.resolveTableEditability(tab: tab, sql: sql)

        let needsMetadataFetch: Bool
        if isEditable, let tableName {
            needsMetadataFetch = !isMetadataCached(tabId: tabId, tableName: tableName)
        } else {
            needsMetadataFetch = false
        }
        /// Captured now, while the result this decision was made against is still the active one.
        let cachedMetadata: ParsedSchemaMetadata? = needsMetadataFetch ? nil : ParsedSchemaMetadata.cached(
            rows: parent.tabSessionRegistry.tableRows(for: tabId),
            primaryKeyColumns: tab.tableContext.primaryKeyColumns
        )

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
                    cancellation: .cancellableRead(lease)
                ) { [queryExecutor = parent.queryExecutor, boundValues] driver in
                    try await queryExecutor.executeQuery(
                        driver: driver,
                        sql: statement.sql,
                        parameters: boundValues.values,
                        rowCap: rowCap
                    )
                }
                CatalogChangeService.post(
                    .statementsRan(connectionId: conn.id, statements: [statement.sql], databaseType: conn.type)
                )

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
                    inlineMetadata: inlineMeta ?? cachedMetadata,
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
                CatalogChangeService.post(
                    .statementsRan(connectionId: conn.id, statements: [statement.sql], databaseType: conn.type)
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard parent.tabExecution.settle(claim) else { return }
                    parent.tabManager.mutate(tabId: tabId) { tab in
                        tab.pagination.isLoadingMore = false
                    }
                    parent.retireQueryTask(.claim(claim))
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
        parent.installQueryTask(parameterizedTask, owner: .claim(claim), lease: lease)
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
            for: parent.connection.type
        )?.parameterStyle ?? .questionMark

        parent.tabManager.mutate(at: index) { tab in
            tab.execution.executionTime = nil
            tab.execution.errorMessage = nil
        }

        let conn = parent.connection
        let tabId = parent.tabManager.tabs[index].id
        let (claim, lease) = parent.beginTabExecution(for: tabId)
        let totalCount = statements.count
        let tabType = parent.tabManager.tabs[index].tabType

        let statementTexts = statements.map(\.sql)
        let transactionKind = OperationKind.worst(of: statementTexts, databaseType: conn.type)
        let rules = SQLLexicalRules(
            databaseType: conn.type,
            descriptor: PluginManager.shared.sqlDialect(for: conn.type)
        )
        let plan = BatchTransactionPolicy.plan(for: statementTexts, databaseType: conn.type, rules: rules)
        let prepared = statements.map { statement in
            prepareStatement(
                statement: statement,
                parameters: parameters,
                style: style,
                tabType: tabType,
                bypassRowLimit: bypassRowLimit,
                rules: rules
            )
        }

        let multiStatementTask = Task { [weak self, parent] in
            guard let self else { return }

            let run = await runMultiStatementTransaction(
                prepared: prepared,
                scope: scope,
                mode: transactionKind.transactionAccessMode,
                plan: plan,
                claim: claim,
                lease: lease
            )
            let outcome = run.outcome
            let sessionNotice = run.plan == .sessionTransaction ? run.sessionState.openTransactionNotice : nil

            let ranStatements: [String]
            switch outcome {
            case .completed:
                ranStatements = prepared.map(\.sentSQL)
            case .failed(let results, let failure, _):
                let ranCount = failure.ranStatementCount(executedCount: results.count, totalCount: prepared.count)
                ranStatements = prepared.prefix(ranCount).map(\.sentSQL)
            case .cancelled:
                ranStatements = prepared.map(\.sentSQL)
            }
            CatalogChangeService.post(
                .statementsRan(connectionId: conn.id, statements: ranStatements, databaseType: conn.type)
            )

            switch outcome {
            case .cancelled(let results):
                guard parent.tabExecution.settle(claim) else { return }
                parent.retireQueryTask(.claim(claim))
                keepStoppedStatements(
                    history: ExecutedStatementHistory(
                        prepared: prepared, results: results, parameters: parameters, connection: conn
                    ),
                    tabId: tabId,
                    sessionNotice: sessionNotice
                )
                parent.reportEndedExecutions([
                    EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
                ])
            case .completed(let results):
                applyCompletedStatements(
                    history: ExecutedStatementHistory(
                        prepared: prepared, results: results, parameters: parameters, connection: conn
                    ),
                    tabId: tabId,
                    claim: claim,
                    sessionNotice: sessionNotice
                )
            case .failed(let results, let failure, let errorDescription):
                handleMultiStatementError(
                    MultiStatementFailureContext(
                        failure: failure,
                        errorDescription: errorDescription,
                        executedCount: results.count,
                        totalCount: totalCount,
                        plan: run.plan,
                        sessionState: run.sessionState
                    ),
                    history: ExecutedStatementHistory(
                        prepared: prepared, results: results, parameters: parameters, connection: conn
                    ),
                    tabId: tabId,
                    claim: claim,
                    statements: statements,
                    timing: PluginQueryTiming.batch(of: results)
                )
            }
        }
        parent.installQueryTask(multiStatementTask, owner: .claim(claim), lease: lease)
    }

    private func prepareStatement(
        statement: SQLStatementScanner.ExecutableStatement,
        parameters: [QueryParameter],
        style: ParameterStyle,
        tabType: TabType,
        bypassRowLimit: Bool,
        rules: SQLLexicalRules
    ) -> PreparedStatement {
        let sql = statement.sql
        let parameterNames = parameters.isEmpty ? [] : SQLParameterExtractor.extractParameters(from: sql)
        let conversion = parameterNames.isEmpty
            ? nil
            : SQLParameterExtractor.convertToNativeStyle(sql: sql, parameters: parameters, style: style)
        let executableSQL = conversion?.sql ?? sql
        let bounded = resolveStatement(sql: executableSQL, tabType: tabType, bypassLimit: bypassRowLimit)
        return PreparedStatement(
            originalSQL: sql,
            executableSQL: executableSQL,
            sentSQL: bounded.sql,
            parameterValues: conversion?.values,
            rowCap: bounded.rowCap,
            anchor: StatementAnchor(statement),
            isCommitPoint: BatchCommitStatement.matches(sql, rules: rules)
        )
    }

    /// The session's own state is read inside the one lease that runs the batch, so nothing can
    /// open a transaction between the answer and the first statement, and read again afterwards
    /// when the run joined one: a failure moves an engine like PostgreSQL from an open transaction
    /// to an aborted one, and the two are told apart in the banner.
    private func runMultiStatementTransaction(
        prepared: [PreparedStatement],
        scope: DatabaseScope,
        mode: PluginTransactionAccessMode,
        plan: BatchTransactionPlan,
        claim: TabExecutionClaim,
        lease: DriverLeaseOwner
    ) async -> MultiStatementRun {
        do {
            return try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: DatabaseManager.shared.executionRoute(for: scope),
                cancellation: .cancellableRead(lease)
            ) { driver in
                let sessionPlan = plan.joining(await driver.heldSessionTransactionState())
                let outcome = await BatchStatementRun.run(
                    prepared,
                    plan: sessionPlan,
                    mode: mode,
                    driver: driver,
                    connectionId: scope.connectionId,
                    gate: self.claimGate(for: claim),
                    failureSQL: \.executableSQL,
                    isCommitPoint: \.isCommitPoint
                ) { statement in
                    try await self.executeStatement(
                        rowCap: statement.rowCap,
                        originalSQL: statement.sentSQL,
                        driver: driver,
                        parameters: statement.parameterValues
                    )
                }
                guard sessionPlan == .sessionTransaction else {
                    return MultiStatementRun(outcome: outcome, plan: sessionPlan, sessionState: .idle)
                }
                return MultiStatementRun(
                    outcome: outcome,
                    plan: sessionPlan,
                    sessionState: await driver.heldSessionTransactionState()
                )
            }
        } catch {
            if DatabaseCancellationDiagnosis.isCancellation(error) || Task.isCancelled {
                return MultiStatementRun(outcome: .cancelled(results: []), plan: plan, sessionState: .unknown)
            }
            return MultiStatementRun(
                outcome: .failed(results: [], failure: .connection, errorDescription: error.localizedDescription),
                plan: plan,
                sessionState: .unknown
            )
        }
    }

    /// The claim questions the run asks, in the one place that holds both the claim and the
    /// registry. Marking and unmarking go through here so a future commit point cannot invent its
    /// own ordering.
    private func claimGate(for claim: TabExecutionClaim) -> BatchClaimGate {
        BatchClaimGate(
            isCurrent: { self.parent.tabExecution.isCurrent(claim) },
            enterCommitPhase: { self.parent.tabExecution.enterUninterruptiblePhase(claim) },
            leaveCommitPhase: { self.parent.tabExecution.leaveUninterruptiblePhase(claim) }
        )
    }

    /// A Stop cannot take back what a plan without a transaction already committed, so the results
    /// and the history of the statements that ran stay rather than being dropped with the run.
    private func keepStoppedStatements(
        history: ExecutedStatementHistory,
        tabId: UUID,
        sessionNotice: String?
    ) {
        guard !history.results.isEmpty else { return }
        recordExecutedStatements(history, tabId: tabId, commitOutcomeIsUnknown: false)
        presentMultiStatementResults(
            tabId: tabId,
            timing: PluginQueryTiming.batch(of: history.results),
            totalRowsAffected: history.results.reduce(0) { $0 + $1.rowsAffected },
            newResultSets: statementResultSets(history, tabId: tabId),
            sessionNotice: sessionNotice
        )
    }

    /// Settles first, then writes. Everything below the gate belongs to a batch that still owns its
    /// tab: its history rows, its outcome notification and its result sets. A superseded batch
    /// writes none of them, which is what the single-statement path has always done.
    private func applyCompletedStatements(
        history: ExecutedStatementHistory,
        tabId: UUID,
        claim: TabExecutionClaim,
        sessionNotice: String?
    ) {
        guard parent.tabExecution.settle(claim) else { return }
        parent.retireQueryTask(.claim(claim))

        let totalRowsAffected = history.results.reduce(0) { $0 + $1.rowsAffected }
        reportOperation(
            kind: .queryBatch,
            claim: claim,
            outcome: .succeeded(
                OperationSummary(rowsAffected: totalRowsAffected, statementCount: history.results.count)
            )
        )
        recordExecutedStatements(history, tabId: tabId, commitOutcomeIsUnknown: false)
        presentMultiStatementResults(
            tabId: tabId,
            timing: PluginQueryTiming.batch(of: history.results),
            totalRowsAffected: totalRowsAffected,
            newResultSets: statementResultSets(history, tabId: tabId),
            sessionNotice: sessionNotice
        )
    }

    private func statementResultSets(_ history: ExecutedStatementHistory, tabId: UUID) -> [ResultSet] {
        zip(history.prepared, history.results).enumerated().map { index, pair in
            let (statement, result) = pair
            return makeStatementResultSet(
                result: result,
                sql: statement.originalSQL,
                index: index,
                baseQuery: statement.executableSQL,
                baseQueryParameterValues: statement.parameterValues?.map { $0 as? String },
                tabId: tabId,
                anchor: statement.anchor
            )
        }
    }

    /// A commit whose connection died before the answer leaves every statement of the batch in a
    /// state nothing can report as done, so history says so rather than claiming a success it
    /// cannot prove.
    private func recordExecutedStatements(
        _ history: ExecutedStatementHistory,
        tabId: UUID,
        commitOutcomeIsUnknown: Bool
    ) {
        let unresolvedOutcome = commitOutcomeIsUnknown
            ? String(localized: "The connection was lost while committing, so this may not be saved.")
            : nil
        for (statement, result) in zip(history.prepared, history.results) {
            recordStatementHistory(
                sql: statement.originalSQL,
                result: result,
                connection: history.connection,
                databaseName: historyDatabaseName(tabId: tabId),
                parameterValues: statement.parameterValues == nil ? nil : history.parameters,
                unresolvedOutcome: unresolvedOutcome
            )
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
        claim: TabExecutionClaim,
        originalParameters: [QueryParameter],
        nativeParameters: [Any?],
        originalSQL: String? = nil,
        anchor: StatementAnchor? = nil
    ) async {
        await MainActor.run { [weak self] in
            guard let self else { return }
            guard parent.tabExecution.settle(claim) else { return }
            parent.retireQueryTask(.claim(claim))
            guard !Task.isCancelled else {
                parent.reportEndedExecutions([
                    EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
                ])
                return
            }
            parent.toolbarState.recordQueryTiming(fetchResult.resolvedTiming, for: claim.tabId)
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
                anchor: anchor,
                timing: fetchResult.resolvedTiming
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
    ///
    /// Every write is below the settle gate, history included. A batch whose claim is gone was
    /// stopped or superseded, and recording its statements there would put work the tab is not
    /// showing into the user's history as if it had been kept.
    private func handleMultiStatementError(
        _ context: MultiStatementFailureContext,
        history: ExecutedStatementHistory,
        tabId: UUID,
        claim: TabExecutionClaim,
        statements: [SQLStatementScanner.ExecutableStatement],
        timing: PluginQueryTiming
    ) {
        let cumulativeTime = timing.total
        let errorDescription = context.errorDescription
        let report = context.report()
        let contextMsg = report.message

        let errorRS = ResultSet(label: report.resultLabel)
        errorRS.errorMessage = contextMsg
        errorRS.statementAnchor = report.failedStatementIndex
            .flatMap { statements.indices.contains($0) ? statements[$0] : nil }
            .map(StatementAnchor.init)

        let failedStatementSQL = report.failedSQL
        guard parent.tabExecution.settle(claim) else { return }
        parent.retireQueryTask(.claim(claim))

        /// Below the settle gate for the same reason the success arm is: a superseded batch
        /// has its error dropped here, so announcing it would report on work the user has
        /// already navigated away from.
        reportOperation(kind: .queryBatch, claim: claim, outcome: .failed(reason: errorDescription))
        recordExecutedStatements(
            history,
            tabId: tabId,
            commitOutcomeIsUnknown: context.failure == .commitOutcomeUnknown
        )

        parent.flushBufferToActiveResult(tabId: tabId, pinnedOnly: true)
        parent.tabManager.mutate(tabId: tabId) { tab in
            tab.execution.errorMessage = contextMsg
            tab.execution.errorQuery = failedStatementSQL
            tab.execution.executionTime = cumulativeTime
            tab.execution.lastExecutedAt = Date()

            tab.display.replaceUnpinnedResults(with: statementResultSets(history, tabId: tabId) + [errorRS])
            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }
        }
        parent.seedBufferFromActiveResult(tabId: tabId)
        if parent.tabManager.selectedTabId == tabId {
            parent.toolbarState.isResultsCollapsed = false
            parent.toolbarState.recordQueryTiming(timing, for: tabId)
            parent.announceQueryError(contextMsg)
        }

        guard let rawSQL = failedStatementSQL else { return }
        let recordSQL = rawSQL.hasSuffix(";") ? rawSQL : rawSQL + ";"
        recordHistory(
            QueryHistoryRecordRequest(
                query: recordSQL,
                connectionId: history.connection.id,
                databaseName: historyDatabaseName(tabId: tabId),
                databaseType: history.connection.type,
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
