//
//  MainContentCoordinator+QueryHelpers.swift
//  TablePro
//
//  Query execution helper methods: schema parsing, metadata caching,
//  phase result application, and error handling.
//

import AppKit
import Foundation
import os
import TableProPluginKit

// MARK: - Query Execution Helpers

extension MainContentCoordinator {
    /// Parsed schema metadata ready to apply to a tab
    struct ParsedSchemaMetadata {
        let columnDefaults: [String: String?]
        let columnForeignKeys: [String: ForeignKeyInfo]
        let columnNullable: [String: Bool]
        let primaryKeyColumn: String?
        let approximateRowCount: Int?
        let columnEnumValues: [String: [String]]
    }

    /// Schema result from parallel or sequential metadata fetch
    typealias SchemaResult = (columnInfo: [ColumnInfo], fkInfo: [ForeignKeyInfo], approximateRowCount: Int?)

    /// Parse a SchemaResult into dictionaries ready for tab assignment
    func parseSchemaMetadata(_ schema: SchemaResult) -> ParsedSchemaMetadata {
        var defaults: [String: String?] = [:]
        var fks: [String: ForeignKeyInfo] = [:]
        var nullable: [String: Bool] = [:]
        for col in schema.columnInfo {
            defaults[col.name] = col.defaultValue
            nullable[col.name] = col.isNullable
        }
        for fk in schema.fkInfo {
            fks[fk.column] = fk
        }
        // Parse enum/set values from column type definitions (MySQL, MariaDB, ClickHouse)
        var enumValues: [String: [String]] = [:]
        for col in schema.columnInfo {
            if let values = ColumnType.parseEnumValues(from: col.dataType) {
                enumValues[col.name] = values
            } else if let values = ColumnType.parseClickHouseEnumValues(from: col.dataType) {
                enumValues[col.name] = values
            }
        }
        return ParsedSchemaMetadata(
            columnDefaults: defaults,
            columnForeignKeys: fks,
            columnNullable: nullable,
            primaryKeyColumn: schema.columnInfo.first(where: { $0.isPrimaryKey })?.name,
            approximateRowCount: schema.approximateRowCount,
            columnEnumValues: enumValues
        )
    }

    /// Check whether metadata is already cached for the given table in a tab
    func isMetadataCached(tabId: UUID, tableName: String) -> Bool {
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            return false
        }
        let tab = tabManager.tabs[idx]
        guard tab.tableName == tableName,
              !tab.columnDefaults.isEmpty,
              tab.primaryKeyColumn != nil else {
            return false
        }
        // Ensure every ENUM/SET column has its allowed values loaded
        let enumSetColumnNames: [String] = tab.resultColumns.enumerated().compactMap { i, name in
            guard i < tab.columnTypes.count,
                  tab.columnTypes[i].isEnumType || tab.columnTypes[i].isSetType else { return nil }
            return name
        }
        if !enumSetColumnNames.isEmpty,
           !enumSetColumnNames.allSatisfy({ tab.columnEnumValues[$0] != nil }) {
            return false
        }
        return true
    }

    /// Await schema metadata from parallel task or fall back to sequential fetch
    func awaitSchemaResult(
        parallelTask: Task<SchemaResult, Error>?,
        tableName: String
    ) async -> SchemaResult? {
        if let parallelTask {
            return try? await parallelTask.value
        }
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return nil }
        do {
            async let cols = driver.fetchColumns(table: tableName)
            async let fks = driver.fetchForeignKeys(table: tableName)
            let (c, f) = try await (cols, fks)
            let approxCount = try? await driver.fetchApproximateRowCount(table: tableName)
            return (columnInfo: c, fkInfo: f, approximateRowCount: approxCount)
        } catch {
            Self.logger.error("Phase 2 schema fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Apply Phase 1 query result data and optional metadata to the tab
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
        connection conn: DatabaseConnection
    ) {
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }

        var updatedTab = tabManager.tabs[idx]
        updatedTab.resultColumns = columns
        updatedTab.columnTypes = columnTypes
        updatedTab.resultRows = rows
        updatedTab.resultVersion += 1
        updatedTab.executionTime = executionTime
        updatedTab.rowsAffected = rowsAffected
        updatedTab.statusMessage = statusMessage
        updatedTab.isExecuting = false
        updatedTab.lastExecutedAt = Date()
        updatedTab.tableName = tableName
        updatedTab.isEditable = isEditable
        // Populate enum values from column types for the enum popover
        for (index, colType) in updatedTab.columnTypes.enumerated() {
            if case .enumType(_, let values) = colType, let vals = values, index < updatedTab.resultColumns.count {
                updatedTab.columnEnumValues[updatedTab.resultColumns[index]] = vals
            }
        }

        // Merge FK metadata into the same update if available
        if let metadata {
            updatedTab.columnDefaults = metadata.columnDefaults
            updatedTab.columnForeignKeys = metadata.columnForeignKeys
            updatedTab.columnNullable = metadata.columnNullable
            for (col, vals) in metadata.columnEnumValues {
                updatedTab.columnEnumValues[col] = vals
            }
            if let approxCount = metadata.approximateRowCount, approxCount > 0 {
                updatedTab.pagination.totalRowCount = approxCount
                updatedTab.pagination.isApproximateRowCount = true
            }
        }
        if hasSchema {
            updatedTab.metadataVersion += 1
        }

        // Create a ResultSet for this single-statement execution
        let rs = ResultSet(label: tableName ?? "Result")
        rs.rowBuffer = updatedTab.rowBuffer
        rs.executionTime = updatedTab.executionTime
        rs.rowsAffected = updatedTab.rowsAffected
        rs.statusMessage = updatedTab.statusMessage
        rs.tableName = updatedTab.tableName
        rs.isEditable = updatedTab.isEditable
        rs.resultVersion = updatedTab.resultVersion
        rs.metadataVersion = updatedTab.metadataVersion
        rs.columnTypes = updatedTab.columnTypes
        rs.columnDefaults = updatedTab.columnDefaults
        rs.columnForeignKeys = updatedTab.columnForeignKeys
        rs.columnEnumValues = updatedTab.columnEnumValues
        rs.columnNullable = updatedTab.columnNullable

        // Keep pinned results, replace unpinned
        let pinned = updatedTab.resultSets.filter(\.isPinned)
        updatedTab.resultSets = pinned + [rs]
        updatedTab.activeResultSetId = rs.id

        // Auto-expand results panel when new data arrives
        if updatedTab.isResultsCollapsed {
            updatedTab.isResultsCollapsed = false
        }
        toolbarState.isResultsCollapsed = false

        tabManager.tabs[idx] = updatedTab

        // Cache column types for selective queries on subsequent page/filter/sort reloads.
        // Only cache from schema-backed table loads (not arbitrary SELECTs which may have partial columns).
        if let tbl = tableName, !tbl.isEmpty, hasSchema {
            let cacheKey = "\(conn.id):\(conn.database):\(tbl)"
            cachedTableColumnTypes[cacheKey] = columnTypes
            cachedTableColumnNames[cacheKey] = columns
        }

        let resolvedPK: String?
        if let pk = metadata?.primaryKeyColumn {
            resolvedPK = pk
        } else if let defaultPK = PluginManager.shared.defaultPrimaryKeyColumn(for: conn.type) {
            resolvedPK = defaultPK
        } else {
            // Preserve existing PK when metadata is cached and not re-fetched
            resolvedPK = tabManager.tabs[idx].primaryKeyColumn
        }

        if let pk = resolvedPK {
            tabManager.tabs[idx].primaryKeyColumn = pk
        }

        if tabManager.selectedTabId == tabId {
            changeManager.configureForTable(
                tableName: tableName ?? "",
                columns: columns,
                primaryKeyColumn: resolvedPK,
                databaseType: conn.type
            )
        }

        QueryHistoryManager.shared.recordQuery(
            query: sql,
            connectionId: conn.id,
            databaseName: conn.database,
            executionTime: executionTime,
            rowCount: rows.count,
            wasSuccessful: true,
            errorMessage: nil
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
                let countResult = try? await mainDriver.execute(
                    query: "SELECT COUNT(*) FROM \(quotedTable)"
                )
                if let firstRow = countResult?.rows.first,
                   let countStr = firstRow.first.flatMap({ $0 }) {
                    count = Int(countStr)
                } else {
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
                    let existing = tabManager.tabs[idx].columnEnumValues
                    let hasNewValues = columnEnumValues.contains { key, value in
                        existing[key] != value
                    }
                    if hasNewValues {
                        for (col, vals) in columnEnumValues {
                            tabManager.tabs[idx].columnEnumValues[col] = vals
                        }
                        tabManager.tabs[idx].metadataVersion += 1
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
                let countResult = try? await mainDriver.execute(
                    query: "SELECT COUNT(*) FROM \(quotedTable)"
                )
                if let firstRow = countResult?.rows.first,
                   let countStr = firstRow.first.flatMap({ $0 }) {
                    count = Int(countStr)
                } else {
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
            errTab.errorMessage = error.localizedDescription
            errTab.isExecuting = false
            errTab.lastExecutedAt = Date()
            tabManager.tabs[idx] = errTab
        }
        toolbarState.setExecuting(false)

        QueryHistoryManager.shared.recordQuery(
            query: sql,
            connectionId: conn.id,
            databaseName: conn.database,
            executionTime: 0,
            rowCount: 0,
            wasSuccessful: false,
            errorMessage: error.localizedDescription
        )

        // Show error alert (with AI fix option when AI is enabled)
        let errorMessage = error.localizedDescription
        let queryCopy = sql
        Task { @MainActor in
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
        let cacheKey = "\(connectionId):\(connection.database):\(tableName)"
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
