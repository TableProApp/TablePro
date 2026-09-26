//
//  MainContentCoordinator+QueryHelpers.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProPluginKit

extension MainContentCoordinator {
    /// The banner appears without the user doing anything, and macOS has no live region to mark it
    /// with, so an announcement is the only way VoiceOver hears about it. Announcements are
    /// app-scoped rather than window-scoped, so a background window has to stay quiet instead of
    /// talking over whatever the front one is doing.
    func announceQueryError(_ message: String) {
        guard contentWindow?.isKeyWindow == true else { return }
        AccessibilityAnnouncement.post(
            String(format: String(localized: "Query failed. %@"), message)
        )
    }

    /// A table tab's SELECT is the app's own, so it may follow a database switch it waited through
    /// onto a pooled connection. The choice belongs to the tab and never to the statement: an editor
    /// SELECT can read a temp table or sit inside the user's open transaction, and moving it to
    /// another connection would lose both.
    func withExecutionDriver<T: Sendable>(
        scope: DatabaseScope,
        isTableTab: Bool,
        lease: DriverLeaseOwner,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        guard isTableTab else {
            return try await services.databaseManager.withScopedDriver(
                scope: scope,
                route: services.databaseManager.executionRoute(for: scope),
                cancellation: .cancellableRead(lease),
                body
            )
        }
        return try await services.databaseManager.withTableReadDriver(
            scope: scope,
            cancellation: .cancellableRead(lease),
            body
        )
    }

    func finishFailedQuery(
        _ error: Error,
        tabId: UUID,
        sql: String,
        connection conn: DatabaseConnection,
        claim: TabExecutionClaim,
        isAutoLoad: Bool,
        trigger: TableLoadTrigger,
        traceToken: TableLoadTraceToken?,
        serverOutput: PluginServerOutput = .none
    ) {
        guard tabExecution.settle(claim) else {
            traceStaleResultDropped(traceToken)
            return
        }
        /// Ahead of every early return below. A cancellation leaves through the next line, and a
        /// disconnected auto-load through the one after, so clearing this alongside the error text
        /// would leave the two commonest failures reporting a load that is no longer running.
        tabManager.mutate(tabId: tabId) { tab in
            tab.pagination.isLoadingMore = false
            tab.pagination.isLoading = false
        }
        retireQueryTask(.claim(claim))
        traceExecutionFailed(traceToken, error: error)
        if DatabaseCancellationDiagnosis.isCancellation(error) || Task.isCancelled {
            reportEndedExecutions([
                EndedExecution(tabId: claim.tabId, startedAt: claim.startedAt, reason: .cancelledByUser)
            ])
            return
        }
        if isAutoLoad, services.databaseManager.driver(for: connectionId)?.status != .connected {
            pendingLoadTrigger = trigger
            return
        }
        handleQueryExecutionError(error, sql: sql, tabId: tabId, connection: conn, serverOutput: serverOutput)
        reportQueryOperation(
            claim: claim, trigger: trigger, outcome: .failed(reason: error.localizedDescription)
        )
    }

    /// The change manager is one per window and holds whichever tab is selected, so a result that
    /// still owns its own tab may not own the edits on screen. Clearing without the selection check
    /// throws away another tab's uncommitted cells and its undo history.
    func clearChangesIfCurrent(claim: TabExecutionClaim) {
        guard tabExecution.ownsContent(claim), !Task.isCancelled else { return }
        guard tabManager.selectedTabId == claim.tabId else { return }
        changeManager.clearChangesAndUndoHistory()
    }

    func resolveRowCap(sql: String, tabType: TabType, bypassLimit: Bool = false) -> Int? {
        queryExecutionCoordinator.resolveRowCap(sql: sql, tabType: tabType, bypassLimit: bypassLimit)
    }

    func resolveStatement(sql: String, tabType: TabType, bypassLimit: Bool = false) -> LeadingRowsStatement {
        queryExecutionCoordinator.resolveStatement(sql: sql, tabType: tabType, bypassLimit: bypassLimit)
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
        read: TableFreshness.Read,
        sql: String,
        connection conn: DatabaseConnection,
        isTruncated: Bool = false,
        queryParameterValues: [QueryParameter]? = nil,
        anchor: StatementAnchor? = nil,
        timing: PluginQueryTiming? = nil,
        viewport: GridReloadIntent = .firstRow,
        serverOutput: PluginServerOutput = .none,
        absentCells: [Int: Set<Int>] = [:]
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
            read: read,
            sql: sql,
            connection: conn,
            isTruncated: isTruncated,
            queryParameterValues: queryParameterValues,
            anchor: anchor,
            timing: timing,
            viewport: viewport,
            serverOutput: serverOutput,
            absentCells: absentCells
        )
    }

    func launchPhase2(
        tableName: String,
        tabId: UUID,
        connectionType: DatabaseType,
        needsMetadataFetch: Bool,
        schemaTask: Task<FetchedTableSchema, Error>?
    ) {
        guard needsMetadataFetch else {
            launchPhase2Count(
                tableName: tableName,
                tabId: tabId,
                connectionType: connectionType
            )
            return
        }
        launchPhase2Work(
            tableName: tableName,
            tabId: tabId,
            connectionType: connectionType,
            schemaTask: schemaTask
        )
    }

    func launchPhase2Work(
        tableName: String,
        tabId: UUID,
        connectionType: DatabaseType,
        schemaTask: Task<FetchedTableSchema, Error>?
    ) {
        queryExecutionCoordinator.launchPhase2Work(
            tableName: tableName,
            tabId: tabId,
            connectionType: connectionType,
            schemaTask: schemaTask
        )
    }

    func launchPhase2Count(
        tableName: String,
        tabId: UUID,
        connectionType: DatabaseType
    ) {
        queryExecutionCoordinator.launchPhase2Count(
            tableName: tableName,
            tabId: tabId,
            connectionType: connectionType
        )
    }

    func handleQueryExecutionError(
        _ error: Error,
        sql: String,
        tabId: UUID,
        connection conn: DatabaseConnection,
        serverOutput: PluginServerOutput = .none
    ) {
        queryExecutionCoordinator.handleQueryExecutionError(
            error,
            sql: sql,
            tabId: tabId,
            connection: conn,
            serverOutput: serverOutput
        )
    }
}
