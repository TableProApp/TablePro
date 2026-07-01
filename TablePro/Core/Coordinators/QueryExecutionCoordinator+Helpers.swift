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

    func parseSchemaMetadata(_ schema: FetchedTableSchema) -> ParsedSchemaMetadata {
        QueryExecutor.parseSchemaMetadata(schema)
    }

    func isMetadataCached(tabId: UUID, tableName: String) -> Bool {
        guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            return false
        }
        let tab = parent.tabManager.tabs[idx]
        let tableRows = parent.tabSessionRegistry.tableRows(for: tab.id)
        let enumSetColumnNames: [String] = tableRows.columns.enumerated().compactMap { i, name in
            guard i < tableRows.columnTypes.count,
                  tableRows.columnTypes[i].isEnumType || tableRows.columnTypes[i].isSetType else { return nil }
            return name
        }
        let enumsReady = enumSetColumnNames.allSatisfy { tableRows.columnEnumValues[$0] != nil }
        let cached = tab.tableContext.tableName == tableName
            && !tableRows.columnDefaults.isEmpty
            && !tab.tableContext.primaryKeyColumns.isEmpty
            && tableRows.foreignKeysFetched
            && enumsReady
        helpersLogger.info(
            "[fk] cache check table=\(tableName, privacy: .public) defaults=\(tableRows.columnDefaults.count) pks=\(tab.tableContext.primaryKeyColumns.count) fkFetched=\(tableRows.foreignKeysFetched) fks=\(tableRows.columnForeignKeys.count) enumsReady=\(enumsReady) cached=\(cached)"
        )
        return cached
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
        guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }

        if let planText = ExplainResultRouter.planText(sql: sql, columns: columns, rows: rows) {
            applyExplainResult(
                tabId: tabId,
                planText: planText,
                executionTime: executionTime,
                rowCount: rows.count,
                sql: sql,
                connection: conn,
                queryParameterValues: queryParameterValues
            )
            return
        }

        let existingTabId = parent.tabManager.tabs[idx].id
        var columnEnumValues: [String: [String]] = [:]
        var columnDefaults: [String: String?] = [:]
        var columnForeignKeys: [String: ForeignKeyInfo] = [:]
        var columnNullable: [String: Bool] = [:]
        var columnComments: [String: String] = [:]
        for (index, colType) in columnTypes.enumerated() {
            if case .enumType(_, let values) = colType, let vals = values, index < columns.count {
                columnEnumValues[columns[index]] = vals
            }
        }

        var foreignKeysFetched = false

        if let metadata {
            columnDefaults = metadata.columnDefaults
            columnForeignKeys = metadata.columnForeignKeys ?? [:]
            columnNullable = metadata.columnNullable
            columnComments = metadata.columnComments
            foreignKeysFetched = metadata.columnForeignKeys != nil
            for (col, vals) in metadata.columnEnumValues {
                columnEnumValues[col] = vals
            }
        } else {
            let existing = parent.tabSessionRegistry.tableRows(for: existingTabId)
            columnDefaults = existing.columnDefaults
            columnForeignKeys = existing.columnForeignKeys
            columnNullable = existing.columnNullable
            columnComments = existing.columnComments
            foreignKeysFetched = existing.foreignKeysFetched
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
            columnNullable: columnNullable,
            columnComments: columnComments,
            foreignKeysFetched: foreignKeysFetched
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

            if let metadata, let approxCount = metadata.approximateRowCount, approxCount > 0,
               !tab.filterState.hasAppliedFilters {
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
                tab.pagination.isLoadingMore = false
            } else {
                tab.pagination.resetLoadMore()
            }
            tab.pagination.baseQueryForMore = sql

            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }
        }
        parent.toolbarState.isResultsCollapsed = false

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
                schemaName: parent.tabManager.tabs[idx].tableContext.schemaName,
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

    private func applyExplainResult(
        tabId: UUID,
        planText: String,
        executionTime: TimeInterval,
        rowCount: Int,
        sql: String,
        connection conn: DatabaseConnection,
        queryParameterValues: [QueryParameter]?
    ) {
        let plan = QueryPlanParserFactory.parser(for: conn.type)?.parse(rawText: planText)

        parent.tabManager.mutate(tabId: tabId) { tab in
            tab.execution.executionTime = executionTime
            tab.execution.rowsAffected = 0
            tab.execution.statusMessage = nil
            tab.execution.isExecuting = false
            tab.execution.lastExecutedAt = Date()
            tab.display.explainText = planText
            tab.display.explainPlan = plan
            tab.display.explainExecutionTime = executionTime
            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }
        }
        parent.toolbarState.isResultsCollapsed = false

        QueryHistoryManager.shared.recordQuery(
            query: sql,
            connectionId: conn.id,
            databaseName: parent.activeDatabaseName,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: true,
            errorMessage: nil,
            parameterValues: queryParameterValues
        )
    }

    func launchPhase2Work(
        tableName: String,
        tabId: UUID,
        capturedGeneration: Int,
        connectionType: DatabaseType,
        schemaTask: Task<FetchedTableSchema, Error>?
    ) {
        let isNonSQL = PluginManager.shared.editorLanguage(for: connectionType) != .sql
        Task(priority: .utility) { [weak self, parent] in
            guard let self else { return }
            guard !parent.isTearingDown else { return }

            let schema = try? await schemaTask?.value
            if schemaTask != nil, schema == nil {
                helpersLogger.error("[fk] phase2 schema fetch failed or cancelled table=\(tableName, privacy: .public)")
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let schema {
                    applySchemaMetadata(schema, tabId: tabId, tableName: tableName)
                }
                if capturedGeneration == parent.queryGeneration {
                    resolveRowCount(
                        tableName: tableName,
                        tabId: tabId,
                        capturedGeneration: capturedGeneration,
                        connectionType: connectionType
                    )
                }
            }

            guard !isNonSQL, let schema else { return }

            let columnEnumValues = await parent.fetchEnumValues(
                columnInfo: schema.columns,
                tableName: tableName,
                connectionType: connectionType
            )
            guard !columnEnumValues.isEmpty else { return }

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                applyEnumValues(columnEnumValues, tabId: tabId, tableName: tableName)
            }
        }
    }

    private func tabShowsTable(_ tabId: UUID, _ tableName: String) -> Bool {
        parent.tabManager.tabs.contains { $0.id == tabId && $0.tableContext.tableName == tableName }
    }

    private func isActiveTab(_ tabId: UUID) -> Bool {
        guard let activeIdx = parent.tabManager.selectedTabIndex,
              activeIdx < parent.tabManager.tabs.count else { return false }
        return parent.tabManager.tabs[activeIdx].id == tabId
    }

    private func applySchemaMetadata(_ schema: FetchedTableSchema, tabId: UUID, tableName: String) {
        guard tabShowsTable(tabId, tableName) else {
            helpersLogger.info("[fk] phase2 apply skipped, tab closed or table changed table=\(tableName, privacy: .public)")
            return
        }
        applyPhase2Metadata(parsed: QueryExecutor.parseSchemaMetadata(schema), tabId: tabId)
    }

    private func applyEnumValues(_ values: [String: [String]], tabId: UUID, tableName: String) {
        guard tabShowsTable(tabId, tableName) else { return }
        let existing = parent.tabSessionRegistry.tableRows(for: tabId)
        let hasNewValues = values.contains { key, value in
            existing.columnEnumValues[key] != value
        }
        guard hasNewValues else { return }

        parent.mutateActiveTableRows(for: tabId) { rows in
            for (col, vals) in values {
                rows.columnEnumValues[col] = vals
            }
            return .columnsReplaced
        }
        parent.tabManager.mutate(tabId: tabId) { $0.metadataVersion += 1 }
        if isActiveTab(tabId) {
            parent.dataTabDelegate?.tableViewCoordinator?.refreshForeignKeyColumns()
        }
    }

    private func applyPhase2Metadata(parsed: ParsedSchemaMetadata, tabId: UUID) {
        guard parent.tabManager.tabs.contains(where: { $0.id == tabId }) else { return }

        parent.mutateActiveTableRows(for: tabId) { rows in
            rows.updateDisplayMetadata(
                columnDefaults: parsed.columnDefaults,
                columnForeignKeys: parsed.columnForeignKeys,
                columnNullable: parsed.columnNullable,
                columnComments: parsed.columnComments
            )
        }

        parent.tabManager.mutate(tabId: tabId) { tab in
            if !parsed.primaryKeyColumns.isEmpty {
                tab.tableContext.primaryKeyColumns = parsed.primaryKeyColumns
            }
            if let approxCount = parsed.approximateRowCount, approxCount > 0,
               !tab.filterState.hasAppliedFilters {
                tab.pagination.totalRowCount = approxCount
                tab.pagination.isApproximateRowCount = true
            }
            tab.metadataVersion += 1
        }

        if parent.tabManager.selectedTabId == tabId, !parsed.primaryKeyColumns.isEmpty {
            parent.changeManager.setPrimaryKeyColumns(parsed.primaryKeyColumns)
        }

        let refreshed = isActiveTab(tabId)
        if refreshed {
            parent.dataTabDelegate?.tableViewCoordinator?.refreshForeignKeyColumns()
        }
        helpersLogger.info(
            "[fk] phase2 applied tab=\(tabId, privacy: .public) fks=\(parsed.columnForeignKeys?.count ?? -1) defaults=\(parsed.columnDefaults.count) activeTabRefreshed=\(refreshed)"
        )
    }

    func launchPhase2Count(
        tableName: String,
        tabId: UUID,
        capturedGeneration: Int,
        connectionType: DatabaseType
    ) {
        resolveRowCount(
            tableName: tableName,
            tabId: tabId,
            capturedGeneration: capturedGeneration,
            connectionType: connectionType
        )
    }

    func resolveRowCount(
        tableName: String,
        tabId: UUID,
        capturedGeneration: Int,
        connectionType: DatabaseType
    ) {
        let isNonSQL = PluginManager.shared.editorLanguage(for: connectionType) != .sql

        Task(priority: .utility) { [weak self, parent] in
            guard let self else { return }
            guard !parent.isTearingDown else { return }

            let prepared: (plan: RowCountPlan, sql: String?) = await MainActor.run {
                guard let tab = parent.tabManager.tabs.first(where: { $0.id == tabId }) else { return (.skip, nil) }
                let plan = Self.rowCountPlan(
                    isNonSQL: isNonSQL,
                    filterState: tab.filterState,
                    approximateRowCount: tab.pagination.totalRowCount,
                    threshold: AppSettingsManager.shared.dataGrid.countRowsIfEstimateLessThan
                )
                guard case let .exactCount(filtered) = plan else { return (plan, nil) }
                let sql = parent.queryBuilder.buildFilteredCountQuery(
                    tableName: tableName,
                    schemaName: tab.tableContext.schemaName,
                    filters: filtered ? tab.filterState.appliedFilters : [],
                    logicMode: tab.filterState.filterLogicMode
                )
                return (plan, sql)
            }

            let outcome: RowCountOutcome
            switch prepared.plan {
            case .skip:
                return
            case .clear:
                outcome = .clear
            case .approximate:
                guard let count = try? await DatabaseManager.shared.withMetadataDriver(connectionId: parent.connectionId, { driver in
                    try await driver.fetchApproximateRowCount(table: tableName)
                }) else { return }
                outcome = .count(count, isApproximate: true)
            case let .filteredNonSQL(filters, logicMode):
                if let count = try? await DatabaseManager.shared.withMetadataDriver(connectionId: parent.connectionId, workload: .bulk, { driver in
                    try await driver.fetchFilteredRowCount(table: tableName, filters: filters, logicMode: logicMode)
                }) {
                    outcome = .count(count, isApproximate: false)
                } else {
                    outcome = .clear
                }
            case .exactCount:
                guard let sql = prepared.sql else { return }
                let count: Int?
                do {
                    count = try await DatabaseManager.shared.withMetadataDriver(connectionId: parent.connectionId, workload: .bulk) { driver in
                        let result = try await driver.execute(query: sql)
                        guard let countStr = result.rows.first?.first?.asText else { return Int?.none }
                        return Int(countStr)
                    }
                } catch {
                    helpersLogger.warning("COUNT query failed for \(tableName): \(error.localizedDescription)")
                    return
                }
                guard let count else { return }
                outcome = .count(count, isApproximate: false)
            }

            await MainActor.run {
                guard capturedGeneration == parent.queryGeneration else { return }
                parent.tabManager.mutate(tabId: tabId) { tab in
                    switch outcome {
                    case let .count(value, isApproximate):
                        tab.pagination.totalRowCount = value
                        tab.pagination.isApproximateRowCount = isApproximate
                    case .clear:
                        tab.pagination.totalRowCount = nil
                        tab.pagination.isApproximateRowCount = false
                    }
                }
            }
        }
    }

    static func rowCountPlan(
        isNonSQL: Bool,
        filterState: TabFilterState,
        approximateRowCount: Int?,
        threshold: Int
    ) -> RowCountPlan {
        if isNonSQL {
            return filterState.hasAppliedFilters
                ? .filteredNonSQL(filters: filterState.appliedFilters, logicMode: filterState.filterLogicMode)
                : .approximate
        }
        let exceedsThreshold = (approximateRowCount ?? 0) >= threshold
        if filterState.hasAppliedFilters {
            return exceedsThreshold ? .clear : .exactCount(filtered: true)
        }
        return exceedsThreshold ? .skip : .exactCount(filtered: false)
    }

    func handleQueryExecutionError(
        _ error: Error,
        sql: String,
        tabId: UUID,
        connection conn: DatabaseConnection,
        trigger: TableLoadTrigger = .userInitiated
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

        guard !trigger.suppressesFailureModal else { return }

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

    func restoreSchemaAndRunQuery(_ schema: String, trigger: TableLoadTrigger = .userInitiated) async {
        guard let driver = DatabaseManager.shared.driver(for: parent.connectionId) else {
            parent.pendingLoadTrigger = trigger
            return
        }
        guard let schemaDriver = driver as? SchemaSwitchable,
              schemaDriver.currentSchema != nil else {
            parent.runQuery(trigger: trigger)
            return
        }
        do {
            try await schemaDriver.switchSchema(to: schema)
            DatabaseManager.shared.updateSession(parent.connectionId) { session in
                session.currentSchema = schema
            }
            parent.toolbarState.currentSchema = schema
            await parent.refreshTables()
        } catch {
            helpersLogger.warning("Failed to restore schema '\(schema, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return
        }
        parent.runQuery(trigger: trigger)
    }
}

enum RowCountPlan: Equatable {
    case skip
    case clear
    case approximate
    case exactCount(filtered: Bool)
    case filteredNonSQL(filters: [TableFilter], logicMode: FilterLogicMode)
}

private enum RowCountOutcome {
    case count(Int, isApproximate: Bool)
    case clear
}
