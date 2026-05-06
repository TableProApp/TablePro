//
//  MainContentCoordinator+QueryHelpers.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProPluginKit

extension MainContentCoordinator {
    func resolveRowCap(sql: String, tabType: TabType) -> Int? {
        QueryExecutor.resolveRowCap(sql: sql, tabType: tabType, databaseType: connection.type)
    }

    func parseSchemaMetadata(_ schema: SchemaResult) -> ParsedSchemaMetadata {
        QueryExecutor.parseSchemaMetadata(schema)
    }

    func awaitSchemaResult(
        parallelTask: Task<SchemaResult, Error>?,
        tableName: String
    ) async -> SchemaResult? {
        await QueryExecutor.awaitSchemaResult(
            connectionId: connectionId,
            parallelTask: parallelTask,
            tableName: tableName
        )
    }

    func isMetadataCached(tabId: UUID, tableName: String) -> Bool {
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            return false
        }
        let tab = tabManager.tabs[idx]
        let tableRows = tabSessionRegistry.tableRows(for: tab.id)
        guard tab.tableContext.tableName == tableName,
              !tableRows.columnDefaults.isEmpty,
              !tab.tableContext.primaryKeyColumns.isEmpty else {
            return false
        }
        let enumSetColumnNames: [String] = tableRows.columns.enumerated().compactMap { i, name in
            guard i < tableRows.columnTypes.count,
                  tableRows.columnTypes[i].isEnumType || tableRows.columnTypes[i].isSetType else { return nil }
            return name
        }
        if !enumSetColumnNames.isEmpty,
           !enumSetColumnNames.allSatisfy({ tableRows.columnEnumValues[$0] != nil }) {
            return false
        }
        return true
    }

    func applyPhase1Result( // swiftlint:disable:this function_parameter_count
        tabId: UUID,
        columns: [String],
        columnTypes: [ColumnType],
        rows: [[String?]],
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
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }

        var updatedTab = tabManager.tabs[idx]
        var columnEnumValues: [String: [String]] = [:]
        var columnDefaults: [String: String?] = [:]
        var columnForeignKeys: [String: ForeignKeyInfo] = [:]
        var columnNullable: [String: Bool] = [:]
        updatedTab.schemaVersion += 1
        updatedTab.execution.executionTime = executionTime
        updatedTab.execution.rowsAffected = rowsAffected
        updatedTab.execution.statusMessage = statusMessage
        updatedTab.execution.isExecuting = false
        updatedTab.execution.lastExecutedAt = Date()
        updatedTab.tableContext.tableName = tableName
        updatedTab.tableContext.isEditable = isEditable
        for (index, colType) in columnTypes.enumerated() {
            if case .enumType(_, let values) = colType, let vals = values, index < columns.count {
                columnEnumValues[columns[index]] = vals
            }
        }

        if let metadata {
            columnDefaults = metadata.columnDefaults
            columnForeignKeys = metadata.columnForeignKeys
            columnNullable = metadata.columnNullable
            for (col, vals) in metadata.columnEnumValues {
                columnEnumValues[col] = vals
            }
            if let approxCount = metadata.approximateRowCount, approxCount > 0 {
                updatedTab.pagination.totalRowCount = approxCount
                updatedTab.pagination.isApproximateRowCount = true
            }
        } else {
            let existing = tabSessionRegistry.tableRows(for: updatedTab.id)
            columnDefaults = existing.columnDefaults
            columnForeignKeys = existing.columnForeignKeys
            columnNullable = existing.columnNullable
            for (col, vals) in existing.columnEnumValues where columnEnumValues[col] == nil {
                columnEnumValues[col] = vals
            }
        }
        if hasSchema {
            updatedTab.metadataVersion += 1
        }

        let newTableRows = TableRows.from(
            queryRows: rows,
            columns: columns,
            columnTypes: columnTypes,
            columnDefaults: columnDefaults,
            columnForeignKeys: columnForeignKeys,
            columnEnumValues: columnEnumValues,
            columnNullable: columnNullable
        )
        setActiveTableRows(newTableRows, for: updatedTab.id)

        let rs = ResultSet(label: tableName ?? "Result", tableRows: newTableRows)
        rs.executionTime = updatedTab.execution.executionTime
        rs.rowsAffected = updatedTab.execution.rowsAffected
        rs.statusMessage = updatedTab.execution.statusMessage
        rs.tableName = updatedTab.tableContext.tableName
        rs.isEditable = updatedTab.tableContext.isEditable
        rs.metadataVersion = updatedTab.metadataVersion

        // Keep pinned results, replace unpinned
        let pinned = updatedTab.display.resultSets.filter(\.isPinned)
        updatedTab.display.resultSets = pinned + [rs]
        updatedTab.display.activeResultSetId = rs.id

        if isTruncated {
            updatedTab.pagination.hasMoreRows = true
            updatedTab.pagination.baseQueryForMore = sql
            updatedTab.pagination.isLoadingMore = false
        } else {
            updatedTab.pagination.resetLoadMore()
        }

        // Auto-expand results panel when new data arrives
        if updatedTab.display.isResultsCollapsed {
            updatedTab.display.isResultsCollapsed = false
        }
        toolbarState.isResultsCollapsed = false

        tabManager.tabs[idx] = updatedTab

        // Cache column types for selective queries on subsequent page/filter/sort reloads.
        // Only cache from schema-backed table loads (not arbitrary SELECTs which may have partial columns).
        if let tbl = tableName, !tbl.isEmpty, hasSchema {
            let cacheKey = "\(conn.id):\(activeDatabaseName):\(tbl)"
            cachedTableColumnTypes[cacheKey] = columnTypes
            cachedTableColumnNames[cacheKey] = columns
        }

        let resolvedPKs: [String]
        if let pks = metadata?.primaryKeyColumns, !pks.isEmpty {
            resolvedPKs = pks
        } else if let defaultPK = PluginManager.shared.defaultPrimaryKeyColumn(for: conn.type) {
            resolvedPKs = [defaultPK]
        } else {
            // Preserve existing PKs when metadata is cached and not re-fetched
            resolvedPKs = tabManager.tabs[idx].tableContext.primaryKeyColumns
        }

        if !resolvedPKs.isEmpty {
            tabManager.tabs[idx].tableContext.primaryKeyColumns = resolvedPKs
        }

        if tabManager.selectedTabId == tabId {
            changeManager.configureForTable(
                tableName: tableName ?? "",
                columns: columns,
                primaryKeyColumns: resolvedPKs,
                databaseType: conn.type
            )
        }

        QueryHistoryManager.shared.recordQuery(
            query: sql,
            connectionId: conn.id,
            databaseName: activeDatabaseName,
            executionTime: executionTime,
            rowCount: rows.count,
            wasSuccessful: true,
            errorMessage: nil,
            parameterValues: queryParameterValues
        )

        // Clear stale edit state immediately so the save banner
        // doesn't linger while Phase 2 metadata loads in background.
        // Only clear if there are no pending edits from the user.
        if tabManager.selectedTabId == tabId, isEditable, !changeManager.hasChanges {
            changeManager.clearChangesAndUndoHistory()
        }
    }

    /// Launch Phase 2 background work: exact COUNT(*) and enum value fetching
    func launchPhase2Work(
        tableName: String,
        tabId: UUID,
        capturedGeneration: Int,
        connectionType: DatabaseType,
        schemaResult: SchemaResult?
    ) {
        let isNonSQL = PluginManager.shared.editorLanguage(for: connectionType) != .sql

        // Phase 2a: Exact row count (background priority to let Phase 1 render first)
        // Redis/non-SQL drivers don't support SELECT COUNT(*); use approximate count instead.
        Task(priority: .background) { [weak self] in
            guard let self else { return }
            guard !self.isTearingDown else { return }
            guard let mainDriver = DatabaseManager.shared.driver(for: connectionId) else { return }

            let count: Int?
            let isApproximate: Bool
            if isNonSQL {
                count = try? await mainDriver.fetchApproximateRowCount(table: tableName)
                isApproximate = true
            } else {
                // Skip exact COUNT(*) if the approximate count exceeds the threshold.
                // PostgreSQL COUNT(*) requires a full sequential scan (MVCC) and can take
                // 10-20+ seconds on multi-million-row tables. Industry standard (TablePlus,
                // pgAdmin, DBeaver) is to use estimates for large tables.
                let threshold = await AppSettingsManager.shared.dataGrid.countRowsIfEstimateLessThan
                let approxCount = await MainActor.run {
                    self.tabManager.tabs.first { $0.id == tabId }?.pagination.totalRowCount
                }
                if let approx = approxCount, approx >= threshold {
                    return // Keep approximate count — skip expensive COUNT(*)
                }

                let quotedTable = mainDriver.quoteIdentifier(tableName)
                do {
                    let countResult = try await mainDriver.execute(
                        query: "SELECT COUNT(*) FROM \(quotedTable)"
                    )
                    if let firstRow = countResult.rows.first,
                       let countStr = firstRow.first.flatMap({ $0 }) {
                        count = Int(countStr)
                    } else {
                        count = nil
                    }
                } catch {
                    Self.logger.warning("COUNT(*) query failed for \(tableName): \(error.localizedDescription)")
                    count = nil
                }
                isApproximate = false
            }

            if let count {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard capturedGeneration == queryGeneration else { return }
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        tabManager.tabs[idx].pagination.totalRowCount = count
                        tabManager.tabs[idx].pagination.isApproximateRowCount = isApproximate
                    }
                }
            }
        }

        // Phase 2b: Fetch enum/set values (not applicable for non-SQL databases)
        guard !isNonSQL else { return }
        guard let enumDriver = DatabaseManager.shared.driver(for: connectionId) else { return }
        Task(priority: .background) { [weak self] in
            guard let self else { return }
            guard !self.isTearingDown else { return }

            // Use schema if available, otherwise fetch column info for enum parsing
            let columnInfo: [ColumnInfo]
            if let schema = schemaResult {
                columnInfo = schema.columnInfo
            } else {
                do {
                    columnInfo = try await enumDriver.fetchColumns(table: tableName)
                } catch {
                    columnInfo = []
                }
            }

            let columnEnumValues = await self.fetchEnumValues(
                columnInfo: columnInfo,
                tableName: tableName,
                driver: enumDriver,
                connectionType: connectionType
            )

            guard !columnEnumValues.isEmpty else {
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard capturedGeneration == queryGeneration else { return }
                guard !Task.isCancelled else { return }
                if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                    let existing = tabSessionRegistry.tableRows(for: tabId)
                    let hasNewValues = columnEnumValues.contains { key, value in
                        existing.columnEnumValues[key] != value
                    }
                    if hasNewValues {
                        mutateActiveTableRows(for: tabId) { rows in
                            for (col, vals) in columnEnumValues {
                                rows.columnEnumValues[col] = vals
                            }
                            return .columnsReplaced
                        }
                        tabManager.tabs[idx].metadataVersion += 1
                        if let activeIdx = tabManager.selectedTabIndex,
                           activeIdx < tabManager.tabs.count,
                           tabManager.tabs[activeIdx].id == tabId {
                            dataTabDelegate?.tableViewCoordinator?.refreshForeignKeyColumns()
                        }
                    }
                }
            }
        }
    }

    /// Launch only the exact COUNT(*) query (when metadata is already cached).
    /// Does not guard on queryGeneration — the count is the same regardless of
    /// which re-execution triggered it, and the repeated query issue means
    /// generation is always stale by the time COUNT finishes.
    func launchPhase2Count(
        tableName: String,
        tabId: UUID,
        capturedGeneration: Int,
        connectionType: DatabaseType
    ) {
        let isNonSQL = PluginManager.shared.editorLanguage(for: connectionType) != .sql

        Task { [weak self] in
            guard let self else { return }
            guard let mainDriver = DatabaseManager.shared.driver(for: connectionId) else { return }

            let count: Int?
            let isApproximate: Bool
            if isNonSQL {
                count = try? await mainDriver.fetchApproximateRowCount(table: tableName)
                isApproximate = true
            } else {
                let threshold = await AppSettingsManager.shared.dataGrid.countRowsIfEstimateLessThan
                let approxCount = await MainActor.run {
                    self.tabManager.tabs.first { $0.id == tabId }?.pagination.totalRowCount
                }
                if let approx = approxCount, approx >= threshold {
                    return
                }

                let quotedTable = mainDriver.quoteIdentifier(tableName)
                do {
                    let countResult = try await mainDriver.execute(
                        query: "SELECT COUNT(*) FROM \(quotedTable)"
                    )
                    if let firstRow = countResult.rows.first,
                       let countStr = firstRow.first.flatMap({ $0 }) {
                        count = Int(countStr)
                    } else {
                        count = nil
                    }
                } catch {
                    Self.logger.warning("COUNT(*) query failed for \(tableName): \(error.localizedDescription)")
                    count = nil
                }
                isApproximate = false
            }

            if let count {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        tabManager.tabs[idx].pagination.totalRowCount = count
                        tabManager.tabs[idx].pagination.isApproximateRowCount = isApproximate
                    }
                }
            }
        }
    }

    /// Handle query execution error: update tab state, record history, show alert
    func handleQueryExecutionError(
        _ error: Error,
        sql: String,
        tabId: UUID,
        connection conn: DatabaseConnection
    ) {
        currentQueryTask = nil
        if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
            var errTab = tabManager.tabs[idx]
            errTab.execution.errorMessage = error.localizedDescription
            errTab.execution.isExecuting = false
            errTab.execution.lastExecutedAt = Date()
            tabManager.tabs[idx] = errTab
        }
        toolbarState.setExecuting(false)

        QueryHistoryManager.shared.recordQuery(
            query: sql,
            connectionId: conn.id,
            databaseName: activeDatabaseName,
            executionTime: 0,
            rowCount: 0,
            wasSuccessful: false,
            errorMessage: error.localizedDescription
        )

        // Show error alert (with AI fix option when AI is enabled)
        let errorMessage = error.localizedDescription
        let queryCopy = sql
        Task {
            if AppSettingsManager.shared.ai.enabled {
                let wantsAIFix = await AlertHelper.showQueryErrorWithAIOption(
                    title: String(localized: "Query Execution Failed"),
                    message: errorMessage,
                    window: contentWindow
                )
                if wantsAIFix {
                    showAIChatPanel()
                    aiViewModel?.handleFixError(query: queryCopy, error: errorMessage)
                }
            } else {
                AlertHelper.showErrorSheet(
                    title: String(localized: "Query Execution Failed"),
                    message: errorMessage,
                    window: contentWindow
                )
            }
        }
    }

    /// Restore schema on the driver and run the query for the current tab.
    /// Unlike `switchSchema`, this does NOT clear tabs or sidebar — it only
    /// switches the driver's search_path so the restored tab's query succeeds.
    func restoreSchemaAndRunQuery(_ schema: String) async {
        guard let driver = DatabaseManager.shared.driver(for: connectionId),
              let schemaDriver = driver as? SchemaSwitchable,
              schemaDriver.currentSchema != nil else {
            runQuery()
            return
        }
        do {
            try await schemaDriver.switchSchema(to: schema)
            DatabaseManager.shared.updateSession(connectionId) { session in
                session.currentSchema = schema
            }
            toolbarState.databaseName = schema
            await refreshTables()
        } catch {
            Self.logger.warning("Failed to restore schema '\(schema, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return
        }
        runQuery()
    }

    /// Build column exclusions for a table using cached column type info.
    /// Returns empty if no cached types exist (first load uses SELECT *).
    func columnExclusions(for tableName: String) -> [ColumnExclusion] {
        let cacheKey = "\(connectionId):\(activeDatabaseName):\(tableName)"
        guard let cachedTypes = cachedTableColumnTypes[cacheKey],
              let cachedCols = cachedTableColumnNames[cacheKey] else {
            return []
        }
        return ColumnExclusionPolicy.exclusions(
            columns: cachedCols,
            columnTypes: cachedTypes,
            databaseType: connection.type,
            quoteIdentifier: queryBuilder.quoteIdentifier
        )
    }
}
