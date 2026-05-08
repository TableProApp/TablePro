//
//  QueryExecutionCoordinator+Helpers.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProPluginKit

private let helpersLogger = Logger(subsystem: "com.TablePro", category: "QueryExecutionCoordinator")

extension QueryExecutionCoordinator {
    func resolveRowCap(sql: String, tabType: TabType) -> Int? {
        QueryExecutor.resolveRowCap(sql: sql, tabType: tabType, databaseType: parent.connection.type)
    }

    func parseSchemaMetadata(_ schema: SchemaResult) -> ParsedSchemaMetadata {
        QueryExecutor.parseSchemaMetadata(schema)
    }

    func awaitSchemaResult(
        parallelTask: Task<SchemaResult, Error>?,
        tableName: String
    ) async -> SchemaResult? {
        await QueryExecutor.awaitSchemaResult(
            connectionId: parent.connectionId,
            parallelTask: parallelTask,
            tableName: tableName
        )
    }

    func isMetadataCached(tabId: UUID, tableName: String) -> Bool {
        guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            return false
        }
        let tab = parent.tabManager.tabs[idx]
        let tableRows = parent.tabSessionRegistry.tableRows(for: tab.id)
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
        guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }

        let existingTabId = parent.tabManager.tabs[idx].id
        var columnEnumValues: [String: [String]] = [:]
        var columnDefaults: [String: String?] = [:]
        var columnForeignKeys: [String: ForeignKeyInfo] = [:]
        var columnNullable: [String: Bool] = [:]
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
        } else {
            let existing = parent.tabSessionRegistry.tableRows(for: existingTabId)
            columnDefaults = existing.columnDefaults
            columnForeignKeys = existing.columnForeignKeys
            columnNullable = existing.columnNullable
            for (col, vals) in existing.columnEnumValues where columnEnumValues[col] == nil {
                columnEnumValues[col] = vals
            }
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
        parent.setActiveTableRows(newTableRows, for: existingTabId)

        parent.tabManager.mutate(at: idx) { tab in
            tab.schemaVersion += 1
            tab.execution.executionTime = executionTime
            tab.execution.rowsAffected = rowsAffected
            tab.execution.statusMessage = statusMessage
            tab.execution.isExecuting = false
            tab.execution.lastExecutedAt = Date()
            tab.tableContext.tableName = tableName
            tab.tableContext.isEditable = isEditable

            if let metadata, let approxCount = metadata.approximateRowCount, approxCount > 0 {
                tab.pagination.totalRowCount = approxCount
                tab.pagination.isApproximateRowCount = true
            }
            if hasSchema {
                tab.metadataVersion += 1
            }

            let rs = ResultSet(label: tableName ?? "Result", tableRows: newTableRows)
            rs.executionTime = tab.execution.executionTime
            rs.rowsAffected = tab.execution.rowsAffected
            rs.statusMessage = tab.execution.statusMessage
            rs.tableName = tab.tableContext.tableName
            rs.isEditable = tab.tableContext.isEditable
            rs.metadataVersion = tab.metadataVersion

            let pinned = tab.display.resultSets.filter(\.isPinned)
            tab.display.resultSets = pinned + [rs]
            tab.display.activeResultSetId = rs.id

            if isTruncated {
                tab.pagination.hasMoreRows = true
                tab.pagination.baseQueryForMore = sql
                tab.pagination.isLoadingMore = false
            } else {
                tab.pagination.resetLoadMore()
            }

            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }
        }
        parent.toolbarState.isResultsCollapsed = false

        if let tbl = tableName, !tbl.isEmpty, hasSchema {
            let cacheKey = "\(conn.id):\(parent.activeDatabaseName):\(tbl)"
            parent.cachedTableColumnTypes[cacheKey] = columnTypes
            parent.cachedTableColumnNames[cacheKey] = columns
        }

        let resolvedPKs: [String]
        if let pks = metadata?.primaryKeyColumns, !pks.isEmpty {
            resolvedPKs = pks
        } else if let defaultPK = PluginManager.shared.defaultPrimaryKeyColumn(for: conn.type) {
            resolvedPKs = [defaultPK]
        } else {
            resolvedPKs = parent.tabManager.tabs[idx].tableContext.primaryKeyColumns
        }

        if !resolvedPKs.isEmpty {
            parent.tabManager.mutate(at: idx) { $0.tableContext.primaryKeyColumns = resolvedPKs }
        }

        if parent.tabManager.selectedTabId == tabId {
            parent.changeManager.configureForTable(
                tableName: tableName ?? "",
                columns: columns,
                primaryKeyColumns: resolvedPKs,
                databaseType: conn.type
            )
        }

        QueryHistoryManager.shared.recordQuery(
            query: sql,
            connectionId: conn.id,
            databaseName: parent.activeDatabaseName,
            executionTime: executionTime,
            rowCount: rows.count,
            wasSuccessful: true,
            errorMessage: nil,
            parameterValues: queryParameterValues
        )

        if parent.tabManager.selectedTabId == tabId, isEditable, !parent.changeManager.hasChanges {
            parent.changeManager.clearChangesAndUndoHistory()
        }
    }

    func launchPhase2Work(
        tableName: String,
        tabId: UUID,
        capturedGeneration: Int,
        connectionType: DatabaseType,
        schemaResult: SchemaResult?
    ) {
        let isNonSQL = PluginManager.shared.editorLanguage(for: connectionType) != .sql

        Task(priority: .background) { [weak self, parent] in
            guard let self else { return }
            guard !parent.isTearingDown else { return }
            guard let mainDriver = DatabaseManager.shared.driver(for: parent.connectionId) else { return }

            let count: Int?
            let isApproximate: Bool
            if isNonSQL {
                count = try? await mainDriver.fetchApproximateRowCount(table: tableName)
                isApproximate = true
            } else {
                let threshold = await AppSettingsManager.shared.dataGrid.countRowsIfEstimateLessThan
                let approxCount = await MainActor.run {
                    self.parent.tabManager.tabs.first { $0.id == tabId }?.pagination.totalRowCount
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
                    helpersLogger.warning("COUNT(*) query failed for \(tableName): \(error.localizedDescription)")
                    count = nil
                }
                isApproximate = false
            }

            if let count {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard capturedGeneration == parent.queryGeneration else { return }
                    parent.tabManager.mutate(tabId: tabId) { tab in
                        tab.pagination.totalRowCount = count
                        tab.pagination.isApproximateRowCount = isApproximate
                    }
                }
            }
        }

        guard !isNonSQL else { return }
        guard let enumDriver = DatabaseManager.shared.driver(for: parent.connectionId) else { return }
        Task(priority: .background) { [weak self, parent] in
            guard let self else { return }
            guard !parent.isTearingDown else { return }

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

            let columnEnumValues = await parent.fetchEnumValues(
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
                guard capturedGeneration == parent.queryGeneration else { return }
                guard !Task.isCancelled else { return }
                guard parent.tabManager.tabs.contains(where: { $0.id == tabId }) else { return }
                let existing = parent.tabSessionRegistry.tableRows(for: tabId)
                let hasNewValues = columnEnumValues.contains { key, value in
                    existing.columnEnumValues[key] != value
                }
                if hasNewValues {
                    parent.mutateActiveTableRows(for: tabId) { rows in
                        for (col, vals) in columnEnumValues {
                            rows.columnEnumValues[col] = vals
                        }
                        return .columnsReplaced
                    }
                    parent.tabManager.mutate(tabId: tabId) { $0.metadataVersion += 1 }
                    if let activeIdx = parent.tabManager.selectedTabIndex,
                       activeIdx < parent.tabManager.tabs.count,
                       parent.tabManager.tabs[activeIdx].id == tabId {
                        parent.dataTabDelegate?.tableViewCoordinator?.refreshForeignKeyColumns()
                    }
                }
            }
        }
    }

    func launchPhase2Count(
        tableName: String,
        tabId: UUID,
        capturedGeneration: Int,
        connectionType: DatabaseType
    ) {
        let isNonSQL = PluginManager.shared.editorLanguage(for: connectionType) != .sql

        Task { [weak self, parent] in
            guard let self else { return }
            guard let mainDriver = DatabaseManager.shared.driver(for: parent.connectionId) else { return }

            let count: Int?
            let isApproximate: Bool
            if isNonSQL {
                count = try? await mainDriver.fetchApproximateRowCount(table: tableName)
                isApproximate = true
            } else {
                let threshold = await AppSettingsManager.shared.dataGrid.countRowsIfEstimateLessThan
                let approxCount = await MainActor.run {
                    self.parent.tabManager.tabs.first { $0.id == tabId }?.pagination.totalRowCount
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
                    helpersLogger.warning("COUNT(*) query failed for \(tableName): \(error.localizedDescription)")
                    count = nil
                }
                isApproximate = false
            }

            if let count {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    parent.tabManager.mutate(tabId: tabId) { tab in
                        tab.pagination.totalRowCount = count
                        tab.pagination.isApproximateRowCount = isApproximate
                    }
                }
            }
        }
    }

    func handleQueryExecutionError(
        _ error: Error,
        sql: String,
        tabId: UUID,
        connection conn: DatabaseConnection
    ) {
        parent.currentQueryTask = nil
        parent.tabManager.mutate(tabId: tabId) { tab in
            tab.execution.errorMessage = error.localizedDescription
            tab.execution.isExecuting = false
            tab.execution.lastExecutedAt = Date()
        }
        parent.toolbarState.setExecuting(false)

        QueryHistoryManager.shared.recordQuery(
            query: sql,
            connectionId: conn.id,
            databaseName: parent.activeDatabaseName,
            executionTime: 0,
            rowCount: 0,
            wasSuccessful: false,
            errorMessage: error.localizedDescription
        )

        let errorMessage = error.localizedDescription
        let queryCopy = sql
        Task { [weak self, parent] in
            guard let self else { return }
            if AppSettingsManager.shared.ai.enabled {
                let wantsAIFix = await AlertHelper.showQueryErrorWithAIOption(
                    title: String(localized: "Query Execution Failed"),
                    message: errorMessage,
                    window: parent.contentWindow
                )
                if wantsAIFix {
                    parent.showAIChatPanel()
                    parent.aiViewModel?.handleFixError(query: queryCopy, error: errorMessage)
                }
            } else {
                AlertHelper.showErrorSheet(
                    title: String(localized: "Query Execution Failed"),
                    message: errorMessage,
                    window: parent.contentWindow
                )
            }
        }
    }

    func restoreSchemaAndRunQuery(_ schema: String) async {
        guard let driver = DatabaseManager.shared.driver(for: parent.connectionId),
              let schemaDriver = driver as? SchemaSwitchable,
              schemaDriver.currentSchema != nil else {
            parent.runQuery()
            return
        }
        do {
            try await schemaDriver.switchSchema(to: schema)
            DatabaseManager.shared.updateSession(parent.connectionId) { session in
                session.currentSchema = schema
            }
            parent.toolbarState.databaseName = schema
            await parent.refreshTables()
        } catch {
            helpersLogger.warning("Failed to restore schema '\(schema, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return
        }
        parent.runQuery()
    }

    func columnExclusions(for tableName: String) -> [ColumnExclusion] {
        let cacheKey = "\(parent.connectionId):\(parent.activeDatabaseName):\(tableName)"
        guard let cachedTypes = parent.cachedTableColumnTypes[cacheKey],
              let cachedCols = parent.cachedTableColumnNames[cacheKey] else {
            return []
        }
        return ColumnExclusionPolicy.exclusions(
            columns: cachedCols,
            columnTypes: cachedTypes,
            databaseType: parent.connection.type,
            quoteIdentifier: parent.queryBuilder.quoteIdentifier
        )
    }
}
