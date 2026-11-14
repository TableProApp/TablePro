//
//  QueryExecutionCoordinator+SingleRun.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

private let singleRunLog = Logger(subsystem: "com.TablePro", category: "QueryParameters")

// The values a parameterized statement sends, handed to the driver and never read again by the caller.
struct BoundStatement: @unchecked Sendable {
    let values: [Any?]
    let parameters: [QueryParameter]
    // The statement as typed, with its `:name` markers: what history and Fix with AI show.
    let originalSQL: String?
}

struct SingleRunRequest {
    let sql: String
    var bound: BoundStatement?
    var isAutoLoad = false
    var trigger: TableLoadTrigger = .userInitiated
    var bypassRowLimit = false
    var anchor: StatementAnchor?
    var install: ResultInstall = .newResult
}

extension QueryExecutionCoordinator {
    func executeQueryWithParameters(
        _ sql: String,
        parameters: [QueryParameter],
        onTab tabId: UUID,
        bypassRowLimit: Bool = false,
        anchor: StatementAnchor? = nil,
        install: ResultInstall = .newResult
    ) {
        let style = PluginMetadataRegistry.shared.snapshot(for: parent.connection.type)?.parameterStyle ?? .questionMark
        let conversion = SQLParameterExtractor.convertToNativeStyle(
            sql: sql,
            parameters: parameters,
            style: style,
            grammar: parent.lexicalGrammar
        )
        singleRunLog.info(
            "Executing parameterized query: \(conversion.sql.prefix(100), privacy: .private) with \(conversion.values.count) parameters"
        )
        var request = SingleRunRequest(sql: conversion.sql)
        request.bound = BoundStatement(values: conversion.values, parameters: parameters, originalSQL: sql)
        request.bypassRowLimit = bypassRowLimit
        request.anchor = anchor
        request.install = install
        startSingleRun(request, onTab: tabId)
    }

    func startSingleRun(_ request: SingleRunRequest, onTab tabId: UUID) {
        guard let run = TabRun.begin(onTab: tabId, parameters: request.bound?.parameters ?? [], in: parent) else { return }
        runSingle(request, in: run)
    }

    // swiftlint:disable:next function_body_length
    private func runSingle(_ request: SingleRunRequest, in run: TabRun) {
        guard let tab = parent.tabManager.tabs.first(where: { $0.id == run.tabId }) else { return }
        let tabId = run.tabId
        let sql = request.sql
        let isAutoLoad = request.isAutoLoad
        let trigger = request.trigger
        let conn = run.connection
        let scope = run.scope

        let traceToken = trigger.tracesLoad ? parent.adoptOrBeginExecutionTrace(tabId: tabId) : nil
        parent.traceExecutionStarted(traceToken, epoch: run.claim.epoch, isAutoLoad: isAutoLoad)

        let statement = resolveStatement(sql: sql, tabType: tab.tabType, bypassLimit: request.bypassRowLimit)
        let rowCap = statement.rowCap
        let (tableName, isEditable) = parent.resolveTableEditability(tab: tab, sql: sql)

        let needsDefinition = parent.tabSessionRegistry.needsDefinition(tabId)
        let needsMetadataFetch = tableName.map { isEditable && !isMetadataCached(tabId: tabId, tableName: $0) } ?? false
        // Captured now, while the result this decision was made against is still the active one.
        let cachedMetadata: ParsedSchemaMetadata? = needsMetadataFetch ? nil : ParsedSchemaMetadata.cached(
            rows: parent.tabSessionRegistry.tableRows(for: tabId),
            context: tab.tableContext
        )
        if let tableName {
            MainContentCoordinator.logger.info(
                "[fk] metadata decision table=\(tableName, privacy: .private(mask: .hash)) isEditable=\(isEditable) needsFetch=\(needsMetadataFetch)"
            )
        }
        let isTableTab = tab.tabType == .table
        let readsView = tab.tableContext.knowsView(named: tableName)
        let (grammar, lengthColumns) = (parent.lexicalGrammar, parent.unloadedValueLengthColumns(for: tab))
        let safeModeIsReadOnly = parent.runsAtReadOnly
        let held = parent.manualCommitRun(skipped: isTableTab || isAutoLoad)
        let bound = request.bound
        let failureOutput = ServerOutputBox()

        run.launch { [weak self] run in
            guard let self else { return }
            let parent = self.parent

            if isAutoLoad, await !parent.connectBeforeAutoLoad(conn, claim: run.claim, trigger: trigger, traceToken: traceToken) {
                return
            }

            let schemaTask = parent.startSchemaFetch(tableName, uncached: needsMetadataFetch, isView: readsView, scope: scope)

            let fetchBeganAt = ContinuousClock.now
            do {
                let (fetchResult, tableEdits) = try await parent.withExecutionDriver(
                    scope: scope,
                    isTableTab: isTableTab,
                    lease: run.lease
                ) { [queryExecutor = parent.queryExecutor, manager = parent.services.databaseManager] driver in
                    let fetched = try await held.running([statement.sql], on: driver) {
                        // Before it runs, so a statement that fails or a connection lost under it is still noted.
                        if !isAutoLoad { await manager.noteSessionStatements([statement.sql], ranOn: driver, scope: scope) }
                        return try await queryExecutor.executeQuery(
                            driver: driver,
                            sql: statement.sql,
                            parameters: bound?.values,
                            rowCap: rowCap,
                            safeModeIsReadOnly: safeModeIsReadOnly,
                            capturingOutputInto: isTableTab ? nil : failureOutput
                        )
                    }
                    let edits = isAutoLoad ? nil : await SucceededStatements.single(
                        statement.sql, scope: scope, databaseType: conn.type, grammar: grammar, ranOn: driver
                    )
                    return (fetched.foldingUnloadedValues(lengthColumns: lengthColumns), edits)
                }
                let fetchEndedAt = ContinuousClock.now
                if !isAutoLoad { MainContentCoordinator.postStatementRan(statement.sql, on: conn, succeeded: tableEdits) }

                guard !Task.isCancelled else {
                    schemaTask?.cancel()
                    parent.traceFetchCancelled(traceToken, began: fetchBeganAt, ended: fetchEndedAt)
                    parent.resetExecutionState(claim: run.claim, executionTime: fetchResult.executionTime)
                    return
                }

                let inlineMeta = needsMetadataFetch
                    ? QueryExecutor.inlineMetadata(from: fetchResult.resultColumnMeta, columns: fetchResult.columns)
                    : nil
                // Rows and definition commit together after a definition change, so new columns never sit under old keys or defaults.
                let definition = needsDefinition ? try? await schemaTask?.value : nil
                let prepared = await parent.preparedPhase1Rows(
                    fetchResult, tabId: tabId, tableName: tableName, isTableTab: isTableTab
                )

                parent.traceFetchCompleted(traceToken, began: fetchBeganAt, ended: fetchEndedAt, result: fetchResult)
                // Settle first: it gates every write below, and sharing a guard with the cancel check would leave the tab claimed forever.
                guard run.settle() else {
                    parent.traceStaleResultDropped(traceToken)
                    schemaTask?.cancel()
                    return
                }
                guard !Task.isCancelled else {
                    parent.traceStaleResultDropped(traceToken)
                    run.reportCancelled()
                    schemaTask?.cancel()
                    return
                }
                guard parent.rereadStillApplies(request.install.source) else {
                    parent.traceStaleResultDropped(traceToken)
                    schemaTask?.cancel()
                    return
                }
                // A menu or value window opened during the read names rows by position, so a tick's rows wait for the next one.
                guard trigger != .autoRefresh || !parent.autoRefreshHeldByTransientUI(tabId) else {
                    schemaTask?.cancel()
                    return
                }
                parent.toolbarState.recordQueryTiming(fetchResult.resolvedTiming, for: tabId)
                parent.traceApplyingResult(traceToken, tabId: tabId)

                let definitionMetadata = parent.adoptLoadedDefinition(definition, of: tableName, in: scope, readBy: run.claim)
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
                    metadata: definitionMetadata ?? inlineMeta ?? cachedMetadata,
                    hasSchema: definitionMetadata != nil,
                    read: TableFreshness.Read(startedAt: run.claim.startedAt, includesDefinition: definitionMetadata != nil),
                    sql: sql,
                    connection: conn,
                    isTruncated: fetchResult.isTruncated,
                    queryParameterValues: bound?.parameters,
                    historySQL: bound?.originalSQL,
                    anchor: request.anchor,
                    timing: fetchResult.resolvedTiming,
                    viewport: request.install.viewport,
                    source: request.install.source,
                    serverOutput: fetchResult.serverOutput,
                    rowLocators: isTableTab ? fetchResult.rowLocators : nil,
                    exportDocuments: fetchResult.exportDocuments,
                    absentCells: fetchResult.absentCells,
                    unloadedCells: fetchResult.unloadedCells,
                    columnOrigins: fetchResult.columnOrigins,
                    prepared: prepared,
                    trigger: trigger
                )
                if let bound {
                    keepBoundValues(bound, onTab: tabId)
                }

                parent.scheduleTraceCompletion(traceToken, outcome: .completed)
                run.report(
                    .query,
                    .succeeded(OperationSummary(rowsReturned: fetchResult.rows.count, rowsAffected: fetchResult.rowsAffected)),
                    trigger: trigger
                )

                // Phase 2 writes onto whatever the tab holds, so only the run that applied its rows starts it.
                parent.launchPhase2AfterApply(
                    tableName: tableName,
                    isEditable: isEditable,
                    tabId: tabId,
                    trigger: trigger,
                    needsMetadataFetch: needsMetadataFetch,
                    schemaTask: schemaTask,
                    claim: run.claim
                )
            } catch {
                schemaTask?.cancel()
                if !isAutoLoad { MainContentCoordinator.postStatementRan(statement.sql, on: conn) }
                parent.finishFailedQuery(
                    error,
                    tabId: tabId,
                    sql: sql,
                    connection: conn,
                    claim: run.claim,
                    isAutoLoad: isAutoLoad,
                    trigger: trigger,
                    traceToken: traceToken,
                    serverOutput: failureOutput.output
                )
            }
        }
    }

    // Load More and a re-read send the result's own values again, not whatever the panel holds by then.
    private func keepBoundValues(_ bound: BoundStatement, onTab tabId: UUID) {
        let parameterValues = bound.values.map(TypedParameterValue.kept)
        let statement = bound.originalSQL.map { NamedParameterStatement(sql: $0, parameters: bound.parameters) }
        parent.tabManager.mutate(tabId: tabId) {
            $0.pagination.baseQueryParameterValues = parameterValues
            $0.display.activeResultSet?.baseQueryParameterValues = parameterValues
            $0.display.activeResultSet?.namedParameterStatement = statement
        }
    }
}
