//
//  MainContentCoordinator+QueryHelpers.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

extension MainContentCoordinator {
    func fixErrorWithAI(query: String, error: String) {
        showAIChatPanel()
        aiViewModel?.handleFixError(query: query, error: error)
    }

    func finishFailedQuery(
        _ error: Error,
        tabId: UUID,
        sql: String,
        connection conn: DatabaseConnection,
        claim: TabExecutionClaim,
        isAutoLoad: Bool,
        trigger: TableLoadTrigger,
        traceToken: TableLoadTraceToken?
    ) {
        tabManager.mutate(tabId: tabId) { tab in
            tab.pagination.isLoadingMore = false
        }
        tabExecution.settle(claim)
        currentQueryTask = nil
        toolbarState.setExecuting(false)
        traceExecutionFailed(traceToken, error: error)
        if DatabaseCancellationDiagnosis.isCancellation(error) || Task.isCancelled { return }
        guard tabExecution.isCurrent(claim) else { return }
        if isAutoLoad, services.databaseManager.driver(for: connectionId)?.status != .connected {
            pendingLoadTrigger = trigger
            return
        }
        handleQueryExecutionError(error, sql: sql, tabId: tabId, connection: conn)
    }

    func clearChangesIfCurrent(claim: TabExecutionClaim) {
        guard tabExecution.isCurrent(claim), !Task.isCancelled else { return }
        changeManager.clearChangesAndUndoHistory()
    }

    func resolveRowCap(sql: String, tabType: TabType, bypassLimit: Bool = false) -> Int? {
        queryExecutionCoordinator.resolveRowCap(sql: sql, tabType: tabType, bypassLimit: bypassLimit)
    }

    func parseSchemaMetadata(_ schema: FetchedTableSchema) -> ParsedSchemaMetadata {
        queryExecutionCoordinator.parseSchemaMetadata(schema)
    }

    func isMetadataCached(tabId: UUID, tableName: String) -> Bool {
        queryExecutionCoordinator.isMetadataCached(tabId: tabId, tableName: tableName)
    }

    func applyPhase1Result( // swiftlint:disable:this function_parameter_count
        tabId: UUID,
        columns: [String],
        columnTypes: [ColumnType],
        rows: [[PluginCellValue]],
        executionTime: TimeInterval,
        rowsAffected: Int,
        statusMessage: String?,
        tableName: String?,
        isEditable: Bool,
        metadata: ParsedSchemaMetadata?,
        hasSchema: Bool,
        sql: String,
        connection conn: DatabaseConnection,
        isTruncated: Bool = false,
        queryParameterValues: [QueryParameter]? = nil
    ) {
        queryExecutionCoordinator.applyPhase1Result(
            tabId: tabId,
            columns: columns,
            columnTypes: columnTypes,
            rows: rows,
            executionTime: executionTime,
            rowsAffected: rowsAffected,
            statusMessage: statusMessage,
            tableName: tableName,
            isEditable: isEditable,
            metadata: metadata,
            hasSchema: hasSchema,
            sql: sql,
            connection: conn,
            isTruncated: isTruncated,
            queryParameterValues: queryParameterValues
        )
    }

    func launchPhase2(
        tableName: String,
        tabId: UUID,
        claim: TabExecutionClaim,
        connectionType: DatabaseType,
        needsMetadataFetch: Bool,
        schemaTask: Task<FetchedTableSchema, Error>?
    ) {
        guard needsMetadataFetch else {
            launchPhase2Count(
                tableName: tableName,
                tabId: tabId,
                claim: claim,
                connectionType: connectionType
            )
            return
        }
        launchPhase2Work(
            tableName: tableName,
            tabId: tabId,
            claim: claim,
            connectionType: connectionType,
            schemaTask: schemaTask
        )
    }

    func launchPhase2Work(
        tableName: String,
        tabId: UUID,
        claim: TabExecutionClaim,
        connectionType: DatabaseType,
        schemaTask: Task<FetchedTableSchema, Error>?
    ) {
        queryExecutionCoordinator.launchPhase2Work(
            tableName: tableName,
            tabId: tabId,
            claim: claim,
            connectionType: connectionType,
            schemaTask: schemaTask
        )
    }

    func launchPhase2Count(
        tableName: String,
        tabId: UUID,
        claim: TabExecutionClaim,
        connectionType: DatabaseType
    ) {
        queryExecutionCoordinator.launchPhase2Count(
            tableName: tableName,
            tabId: tabId,
            claim: claim,
            connectionType: connectionType
        )
    }

    func handleQueryExecutionError(
        _ error: Error,
        sql: String,
        tabId: UUID,
        connection conn: DatabaseConnection
    ) {
        queryExecutionCoordinator.handleQueryExecutionError(
            error,
            sql: sql,
            tabId: tabId,
            connection: conn
        )
    }
}
