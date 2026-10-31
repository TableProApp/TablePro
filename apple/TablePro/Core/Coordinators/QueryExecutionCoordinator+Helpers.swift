//
//  QueryExecutionCoordinator+Helpers.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

private let helpersLogger = Logger(subsystem: "com.TablePro", category: "QueryExecutionCoordinator")

extension QueryExecutionCoordinator {
    func resolveRowCap(sql: String, tabType: TabType, bypassLimit: Bool = false) -> Int? {
        guard !bypassLimit,
              let cap = QueryExecutor.resolveRowCap(
                  sql: sql, tabType: tabType, databaseType: parent.connection.type
              )
        else {
            return nil
        }
        guard !SQLLimitDetector.hasExplicitRowLimit(
            sql,
            autoLimitStyle: PluginManager.shared.autoLimitStyle(for: parent.connection.type),
            grammar: parent.lexicalGrammar
        ) else {
            return nil
        }
        return cap
    }

    func resolveStatement(sql: String, tabType: TabType, bypassLimit: Bool = false) -> LeadingRowsStatement {
        LeadingRowsStatement.resolve(
            sql,
            rowCap: resolveRowCap(sql: sql, tabType: tabType, bypassLimit: bypassLimit),
            databaseType: parent.connection.type
        )
    }

    func parseSchemaMetadata(_ schema: FetchedTableSchema) -> ParsedSchemaMetadata {
        QueryExecutor.parseSchemaMetadata(
            schema,
            rowMatchExcludedTypePrefixes: PluginManager.shared.rowMatchExcludedTypePrefixes(
                for: parent.connection.type
            ),
            rowMatchTextTypePrefixes: PluginManager.shared.rowMatchTextTypePrefixes(
                for: parent.connection.type
            )
        )
    }

    // History belongs to the database the tab ran on, not wherever the sidebar points when the entry is written.
    func historyDatabaseName(tabId: UUID) -> String {
        guard let tab = parent.tabManager.tabs.first(where: { $0.id == tabId }) else {
            return parent.browseDatabaseName
        }
        return parent.scope(for: tab)?.database ?? parent.browseDatabaseName
    }

    func historySchemaName(tabId: UUID) -> String? {
        guard let tab = parent.tabManager.tabs.first(where: { $0.id == tabId }) else { return nil }
        return parent.scope(for: tab)?.schema
    }

    // A table tab's SQL is app-generated: recorded so the user can audit it, but not something they authored.
    func historySource(tabId: UUID) -> QueryHistorySource {
        guard let tab = parent.tabManager.tabs.first(where: { $0.id == tabId }) else { return .editor }
        return tab.tabType == .table ? .tableBrowse : .editor
    }

    // Never after a definition change: the cached keys, defaults, generated columns and match policy describe the old table.
    func isMetadataCached(tabId: UUID, tableName: String) -> Bool {
        guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              !parent.tabSessionRegistry.needsDefinition(tabId)
        else {
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
            "[fk] cache check table=\(tableName, privacy: .private(mask: .hash)) defaults=\(tableRows.columnDefaults.count) pks=\(tab.tableContext.primaryKeyColumns.count) fkFetched=\(tableRows.foreignKeysFetched) fks=\(tableRows.columnForeignKeys.count) enumsReady=\(enumsReady) cached=\(cached)"
        )
        return cached
    }

    // Leaves `foreignKeysFetched` unset: the prefetch covers only FK arrows, and claiming more lets `isMetadataCached` skip it.
    private func prefetchedForeignKeys(tabIndex: Int, tableName: String) -> [String: ForeignKeyInfo]? {
        guard tabIndex < parent.tabManager.tabs.count,
              let scope = parent.scope(for: parent.tabManager.tabs[tabIndex])
        else { return nil }
        if let cached = SchemaForeignKeyStore.shared.foreignKeysByColumn(for: scope, table: tableName) {
            return cached
        }
        parent.prefetchForeignKeys(scope: scope)
        return nil
    }

    struct ResolvedDisplayMetadata {
        var columnDefaults: [String: String?] = [:]
        var columnForeignKeys: [String: ForeignKeyInfo] = [:]
        var columnEnumValues: [String: [String]] = [:]
        var columnNullable: [String: Bool] = [:]
        var columnComments: [String: String] = [:]
        var columnIdentity: [String: IdentityKind] = [:]
        var columnDeclaredTypes: [String: String] = [:]
        var generatedColumns: Set<String> = []
        var rowMatchPolicy: RowMatchPolicy = .none
        var hasAuthoritativeSchema = false
        var foreignKeysFetched = false
    }

    // The caller's snapshot, never re-read: selecting a pinned result mid-rerun gave the rerun that result's identity.
    private func resolveDisplayMetadata(
        metadata: ParsedSchemaMetadata?,
        columns: [String],
        columnTypes: [ColumnType],
        tabIndex: Int,
        tableName: String?
    ) -> ResolvedDisplayMetadata {
        var resolved = ResolvedDisplayMetadata()
        for (index, colType) in columnTypes.enumerated() {
            if case .enumType(_, let values) = colType, let vals = values, index < columns.count {
                resolved.columnEnumValues[columns[index]] = vals
            }
        }

        if let metadata {
            resolved.columnDefaults = metadata.columnDefaults
            resolved.columnForeignKeys = metadata.columnForeignKeys ?? [:]
            resolved.columnNullable = metadata.columnNullable
            resolved.columnComments = metadata.columnComments
            resolved.columnIdentity = metadata.columnIdentity
            resolved.columnDeclaredTypes = metadata.columnDeclaredTypes
            resolved.generatedColumns = metadata.generatedColumns
            resolved.rowMatchPolicy = metadata.rowMatchPolicy
            resolved.hasAuthoritativeSchema = metadata.isAuthoritative
            resolved.foreignKeysFetched = metadata.columnForeignKeys != nil
            for (col, vals) in metadata.columnEnumValues {
                resolved.columnEnumValues[col] = vals
            }
        }

        if resolved.columnForeignKeys.isEmpty, !resolved.foreignKeysFetched, let tableName {
            resolved.columnForeignKeys = prefetchedForeignKeys(tabIndex: tabIndex, tableName: tableName) ?? [:]
        }
        return resolved
    }

    // Same-table keys carry over until phase 2 reports, but never across a definition change: they describe the old table.
    static func resolvedPrimaryKeys(
        reported: [String]?,
        engineDefault: String?,
        previous: [String],
        definitionChanged: Bool
    ) -> [String] {
        if let reported, !reported.isEmpty {
            return reported
        }
        if let engineDefault {
            return [engineDefault]
        }
        return definitionChanged ? [] : previous
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
        historySQL: String? = nil,
        anchor: StatementAnchor? = nil,
        timing: PluginQueryTiming? = nil,
        viewport: GridReloadIntent = .firstRow,
        source: ResultSourceChange = .newSource,
        serverOutput: PluginServerOutput = .none,
        rowLocators: [String?]? = nil,
        absentCells: [Int: Set<Int>] = [:],
        unloadedCells: [Int: [Int: Int]] = [:]
    ) {
        guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }

        if let routed = ExplainResultRouter.route(
            sql: sql,
            columns: columns,
            rows: rows,
            databaseType: conn.type,
            declaredVariants: conn.type.explainVariants
        ) {
            applyExplainResult(
                tabId: tabId,
                routed: routed,
                executionTime: executionTime,
                rowCount: rows.count,
                sql: sql,
                historySQL: historySQL ?? sql,
                connection: conn,
                queryParameterValues: queryParameterValues,
                anchor: anchor,
                timing: timing
            )
            return
        }

        let existingTabId = parent.tabManager.tabs[idx].id
        let resolved = resolveDisplayMetadata(
            metadata: metadata,
            columns: columns,
            columnTypes: columnTypes,
            tabIndex: idx,
            tableName: tableName
        )
        let generatedColumns = resolved.generatedColumns

        let newTableRows = TableRows.from(
            queryRows: rows,
            columns: columns,
            columnTypes: columnTypes,
            columnDefaults: resolved.columnDefaults,
            columnForeignKeys: resolved.columnForeignKeys,
            columnEnumValues: resolved.columnEnumValues,
            columnNullable: resolved.columnNullable,
            columnComments: resolved.columnComments,
            columnIdentity: resolved.columnIdentity,
            columnDeclaredTypes: resolved.columnDeclaredTypes,
            generatedColumns: generatedColumns,
            rowMatchPolicy: resolved.rowMatchPolicy,
            hasAuthoritativeSchema: resolved.hasAuthoritativeSchema,
            foreignKeysFetched: resolved.foreignKeysFetched,
            rowLocators: rowLocators,
            absentCells: absentCells,
            unloadedCells: unloadedCells
        )
        let previousTableName = parent.tabManager.tabs[idx].tableContext.tableName
        let definitionChanged = parent.tabSessionRegistry.needsDefinition(existingTabId)
        parent.flushBufferToActiveResult(tabId: existingTabId, pinnedOnly: true)
        parent.setActiveTableRows(newTableRows, for: existingTabId, viewport: viewport, source: source)
        // A pre-change count can land late with the old total; a kept total over the auto-count threshold stops this read's count.
        let answeredRowsChange = parent.tabSessionRegistry.recordRead(read, for: existingTabId)
        let usesBrowseSearch = parent.filterCoordinator.usesBrowseSearch

        parent.tabManager.mutate(at: idx) { tab in
            tab.schemaVersion += 1
            tab.execution.executionTime = executionTime
            tab.execution.rowsAffected = rowsAffected
            tab.execution.statusMessage = statusMessage
            tab.execution.lastExecutedAt = Date()
            tab.tableContext.tableName = tableName
            tab.tableContext.isEditable = isEditable
            tab.pagination.isLoading = false

            if answeredRowsChange {
                tab.pagination.retireDerivedRowCount()
            }
            if let metadata, let approxCount = metadata.approximateRowCount, approxCount > 0,
               !tab.filterState.narrowsRows(browseSearchIsSupported: usesBrowseSearch) {
                tab.pagination.applyDerivedRowCount(approxCount, isApproximate: true)
            }
            if hasSchema {
                tab.metadataVersion += 1
            }

            let rs = ResultSet(
                label: ResultSet.label(tableName: tableName, anchor: anchor, index: tab.display.pinnedResultCount),
                tableRows: newTableRows
            )
            rs.statementAnchor = anchor
            rs.executionTime = tab.execution.executionTime
            rs.rowsAffected = tab.execution.rowsAffected
            rs.statusMessage = tab.execution.statusMessage
            rs.isTruncated = isTruncated
            rs.baseQuery = sql
            rs.serverOutput = serverOutput

            if case .reread(let target) = source, let outgoingId = target.resultId,
               tab.display.resultSets.contains(where: { $0.id == outgoingId }) {
                tab.display.replaceResult(outgoingId, with: rs)
            } else {
                tab.display.replaceUnpinnedResults(with: [rs])
            }

            if isTruncated {
                tab.pagination.hasMoreRows = true
                tab.pagination.isLoadingMore = false
            } else {
                tab.pagination.resetLoadMore()
            }
            tab.pagination.setBaseQueryForMore(sql, parameterValues: nil)

            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }
        }
        parent.toolbarState.isResultsCollapsed = false

        let resolvedPKs = Self.resolvedPrimaryKeys(
            reported: metadata?.primaryKeyColumns,
            engineDefault: PluginManager.shared.defaultPrimaryKeyColumn(for: conn.type),
            previous: tableName == previousTableName ? parent.tabManager.tabs[idx].tableContext.primaryKeyColumns : [],
            definitionChanged: definitionChanged
        )

        parent.tabManager.mutate(at: idx) { tab in
            tab.tableContext.primaryKeyColumns = resolvedPKs
            if let viewRowEditing = metadata?.viewRowEditing {
                tab.tableContext.viewRowEditing = viewRowEditing
            }
        }
        captureOrigin(
            tabIndex: idx,
            tabId: tabId,
            tableName: tableName,
            primaryKeyColumns: resolvedPKs,
            isEditable: isEditable
        )

        if parent.tabManager.selectedTabId == tabId {
            parent.changeManager.configureForTable(
                tableName: tableName ?? "",
                schemaName: parent.tabManager.tabs[idx].tableContext.schemaName,
                columns: columns,
                primaryKeyColumns: resolvedPKs,
                databaseType: conn.type,
                generatedColumns: generatedColumns,
                rowMatchPolicy: resolved.rowMatchPolicy,
                columnTypeNames: newTableRows.columnTypeNames
            )
        }

        recordHistory(
            QueryHistoryRecordRequest(
                query: historySQL ?? sql,
                connectionId: conn.id,
                databaseName: historyDatabaseName(tabId: tabId),
                databaseType: conn.type,
                schemaName: historySchemaName(tabId: tabId),
                source: historySource(tabId: tabId),
                executionTime: executionTime,
                rowCount: rows.count,
                wasSuccessful: true,
                timing: timing
            )
        )

        if parent.tabManager.selectedTabId == tabId, isEditable, !parent.changeManager.hasChanges {
            parent.changeManager.clearChangesAndUndoHistory()
        }
    }

    private func applyExplainResult(
        tabId: UUID,
        routed: ExplainResultRouter.RoutedPlan,
        executionTime: TimeInterval,
        rowCount: Int,
        sql: String,
        historySQL: String,
        connection conn: DatabaseConnection,
        queryParameterValues: [QueryParameter]?,
        anchor: StatementAnchor? = nil,
        timing: PluginQueryTiming? = nil
    ) {
        let databaseName = historyDatabaseName(tabId: tabId)
        let schemaName = historySchemaName(tabId: tabId)
        let historyId = UUID()
        let captured = QueryPlanCaptureBuilder.make(
            subjectSQL: routed.subjectSQL,
            rawPlan: routed.rawText,
            format: routed.format,
            variantKey: routed.variantKey,
            scope: QueryPlanScope(
                connectionId: conn.id,
                databaseType: conn.type,
                databaseName: databaseName,
                schemaName: schemaName
            ),
            executionTime: executionTime,
            capturedAt: Date(),
            historyId: historyId,
            queryParameters: queryParameterValues
        )
        parent.flushBufferToActiveResult(tabId: tabId, pinnedOnly: true)
        parent.tabManager.mutate(tabId: tabId) { tab in
            tab.execution.executionTime = executionTime
            tab.execution.rowsAffected = 0
            tab.execution.statusMessage = nil
            tab.execution.lastExecutedAt = Date()
            tab.pagination.resetLoadMore()
            tab.display.replaceUnpinnedResults(
                with: [ExplainResultSetFactory.make(
                    rawText: routed.rawText,
                    plan: routed.plan,
                    sql: sql,
                    executionTime: executionTime,
                    anchor: anchor,
                    planContext: captured.context
                )]
            )
            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }
        }
        parent.seedBufferFromActiveResult(tabId: tabId)
        parent.toolbarState.isResultsCollapsed = false

        recordHistory(
            QueryHistoryRecordRequest(
                id: historyId,
                query: historySQL,
                connectionId: conn.id,
                databaseName: databaseName,
                databaseType: conn.type,
                schemaName: schemaName,
                source: .explain,
                executionTime: executionTime,
                rowCount: rowCount,
                wasSuccessful: true,
                planCapture: captured.capture,
                timing: timing
            )
        )
    }

    func launchPhase2Work(
        tableName: String,
        tabId: UUID,
        connectionType: DatabaseType,
        schemaTask: Task<FetchedTableSchema, Error>?
    ) {
        let isNonSQL = PluginManager.shared.editorLanguage(for: connectionType) != .sql
        let contentEpoch = parent.tabExecution.contentEpoch(for: tabId)
        let resultSetId = parent.tabManager.tabs.first { $0.id == tabId }?.display.activeResultSetId
        Task(priority: .utility) { [weak self, parent] in
            // The caller marked the total pending; every exit that skips `resolveRowCount` must release it, or Count Exactly never returns.
            guard let self else {
                parent.releaseCountPending(for: tabId)
                return
            }
            guard !parent.isTearingDown else { return }

            let schema = try? await schemaTask?.value
            if schemaTask != nil, schema == nil {
                helpersLogger.error("[fk] phase2 schema fetch failed or cancelled table=\(tableName, privacy: .private(mask: .hash))")
            }

            await MainActor.run { [weak self] in
                guard let self else {
                    parent.releaseCountPending(for: tabId)
                    return
                }
                if let schema {
                    applySchemaMetadata(schema, tabId: tabId, tableName: tableName, resultSetId: resultSetId)
                }
                // A retarget or newer run owns the tab now with its own pending mark; clearing here would release the successor's.
                guard parent.tabExecution.isSameContent(contentEpoch, for: tabId) else { return }
                resolveRowCount(
                    tableName: tableName,
                    tabId: tabId,
                    connectionType: connectionType
                )
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
                applyEnumValues(columnEnumValues, tabId: tabId, tableName: tableName, resultSetId: resultSetId)
            }
        }
    }

    // `QueryTab.tableContext` tracks the newest run, so each result carries its own origin or edits hit whatever ran last (#2243).
    func captureOrigin(
        tabIndex: Int,
        tabId: UUID,
        tableName: String?,
        primaryKeyColumns: [String],
        isEditable: Bool
    ) {
        guard tabIndex < parent.tabManager.tabs.count else { return }
        let context = parent.tabManager.tabs[tabIndex].tableContext
        parent.tabManager.tabs[tabIndex].display.activeResultSet?.origin = ResultOrigin(
            tableName: tableName,
            schemaName: context.schemaName,
            databaseName: historyDatabaseName(tabId: tabId),
            primaryKeyColumns: primaryKeyColumns,
            isEditable: isEditable,
            isView: context.isView,
            objectType: context.objectType,
            keysResolved: true,
            viewRowEditing: context.viewRowEditing
        )
    }

    // Keyed on the result the fetch was for: keying on the tab's table name painted one table's FKs and keys onto another's rows.
    private func resultStillActive(_ tabId: UUID, _ resultSetId: UUID?) -> Bool {
        parent.tabManager.tabs.contains { $0.id == tabId && $0.display.activeResultSetId == resultSetId }
    }

    private func isActiveTab(_ tabId: UUID) -> Bool {
        guard let activeIdx = parent.tabManager.selectedTabIndex,
              activeIdx < parent.tabManager.tabs.count else { return false }
        return parent.tabManager.tabs[activeIdx].id == tabId
    }

    private func applySchemaMetadata(
        _ schema: FetchedTableSchema,
        tabId: UUID,
        tableName: String,
        resultSetId: UUID?
    ) {
        let parsed = parseSchemaMetadata(schema)
        guard resultStillActive(tabId, resultSetId) else {
            // Dropping it left the result with no account of server-owned columns, and nothing re-fetches on the way back.
            applyPhase2MetadataToInactiveResult(parsed: parsed, tabId: tabId, resultSetId: resultSetId)
            helpersLogger.info("[fk] phase2 applied to an inactive result table=\(tableName, privacy: .private(mask: .hash))")
            return
        }
        applyPhase2Metadata(parsed: parsed, tabId: tabId)
    }

    private func applyPhase2MetadataToInactiveResult(
        parsed: ParsedSchemaMetadata,
        tabId: UUID,
        resultSetId: UUID?
    ) {
        guard let resultSetId,
              let tab = parent.tabManager.tabs.first(where: { $0.id == tabId }),
              let resultSet = tab.display.resultSets.first(where: { $0.id == resultSetId })
        else { return }

        resultSet.tableRows.updateDisplayMetadata(
            columnDefaults: parsed.columnDefaults,
            columnForeignKeys: parsed.columnForeignKeys,
            columnNullable: parsed.columnNullable,
            columnComments: parsed.columnComments,
            columnIdentity: parsed.columnIdentity,
            columnDeclaredTypes: parsed.columnDeclaredTypes,
            generatedColumns: parsed.generatedColumns,
            rowMatchPolicy: parsed.rowMatchPolicy,
            hasAuthoritativeSchema: parsed.isAuthoritative
        )
        if !parsed.primaryKeyColumns.isEmpty {
            resultSet.origin?.primaryKeyColumns = parsed.primaryKeyColumns
            resultSet.origin?.keysResolved = true
        }
        // Phase 2 always read the schema afresh, so a nil answer replaces a stale one.
        if resultSet.origin?.isView == true {
            resultSet.origin?.viewRowEditing = parsed.viewRowEditing
        }
    }

    private func applyEnumValues(
        _ values: [String: [String]],
        tabId: UUID,
        tableName: String,
        resultSetId: UUID?
    ) {
        guard resultStillActive(tabId, resultSetId) else { return }
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
    }

    private func applyPhase2Metadata(parsed: ParsedSchemaMetadata, tabId: UUID) {
        guard parent.tabManager.tabs.contains(where: { $0.id == tabId }) else { return }

        parent.mutateActiveTableRows(for: tabId) { rows in
            rows.updateDisplayMetadata(
                columnDefaults: parsed.columnDefaults,
                columnForeignKeys: parsed.columnForeignKeys,
                columnNullable: parsed.columnNullable,
                columnComments: parsed.columnComments,
                columnIdentity: parsed.columnIdentity,
                columnDeclaredTypes: parsed.columnDeclaredTypes,
                generatedColumns: parsed.generatedColumns,
                rowMatchPolicy: parsed.rowMatchPolicy,
                hasAuthoritativeSchema: parsed.isAuthoritative
            )
        }

        let usesBrowseSearch = parent.filterCoordinator.usesBrowseSearch
        parent.tabManager.mutate(tabId: tabId) { tab in
            if !parsed.primaryKeyColumns.isEmpty {
                tab.tableContext.primaryKeyColumns = parsed.primaryKeyColumns
                tab.display.activeResultSet?.origin?.primaryKeyColumns = parsed.primaryKeyColumns
                tab.display.activeResultSet?.origin?.keysResolved = true
            }
            if tab.tableContext.resolvedObjectKind() == .view {
                tab.tableContext.viewRowEditing = parsed.viewRowEditing
                tab.display.activeResultSet?.origin?.viewRowEditing = parsed.viewRowEditing
            }
            if let approxCount = parsed.approximateRowCount, approxCount > 0,
               !tab.filterState.narrowsRows(browseSearchIsSupported: usesBrowseSearch) {
                tab.pagination.applyDerivedRowCount(approxCount, isApproximate: true)
            }
            tab.metadataVersion += 1
        }

        if parent.tabManager.selectedTabId == tabId, !parsed.primaryKeyColumns.isEmpty {
            parent.changeManager.setPrimaryKeyColumns(parsed.primaryKeyColumns)
        }

        if parent.tabManager.selectedTabId == tabId {
            parent.changeManager.setGeneratedColumns(parsed.generatedColumns)
            parent.changeManager.setRowMatchPolicy(parsed.rowMatchPolicy)
        }

        // The metadata delta rebuilt the model's columns; the foreign key arrows need the rows redrawn.
        let refreshed = isActiveTab(tabId)
        if refreshed {
            parent.existingGridModel(forTab: tabId)?.repaintAllRows()
        }
        helpersLogger.info(
            "[fk] phase2 applied tab=\(tabId, privacy: .public) fks=\(parsed.columnForeignKeys?.count ?? -1) defaults=\(parsed.columnDefaults.count) activeTabRefreshed=\(refreshed)"
        )
    }

    func launchPhase2Count(
        tableName: String,
        tabId: UUID,
        connectionType: DatabaseType
    ) {
        resolveRowCount(
            tableName: tableName,
            tabId: tabId,
            connectionType: connectionType
        )
    }

    // Checks content identity, not the execution claim: the claim settles before phase 2 dispatches, so the count never landed.
    func resolveRowCount(
        tableName: String,
        tabId: UUID,
        connectionType: DatabaseType
    ) {
        let isNonSQL = PluginManager.shared.editorLanguage(for: connectionType) != .sql
        let countsAutomatically = PluginManager.shared.countsRowsAutomatically(for: connectionType)
        let contentEpoch = parent.tabExecution.contentEpoch(for: tabId)
        let token = UUID()

        parent.tabManager.mutate(tabId: tabId) { $0.pagination.isCountPending = true }

        let task = Task(priority: .utility) { [weak self, parent] in
            guard let self else { return }
            guard !parent.isTearingDown else { return }

            let prepared: (plan: RowCountPlan, count: ExactCountInput?, scope: DatabaseScope?) = await MainActor.run {
                guard let tab = parent.tabManager.tabs.first(where: { $0.id == tabId }) else {
                    return (.skip, nil, nil)
                }
                let scope = parent.scope(for: tab)
                let plan = Self.rowCountPlan(
                    isNonSQL: isNonSQL,
                    filterState: tab.filterState,
                    approximateRowCount: tab.pagination.totalRowCount,
                    threshold: AppSettingsManager.shared.dataGrid.countRowsIfEstimateLessThan,
                    countsAutomatically: countsAutomatically,
                    browseSearch: parent.filterCoordinator.activeBrowseSearch(for: tab.filterState)
                )
                guard case let .exactCount(filtered) = plan else { return (plan, nil, scope) }
                let queryColumns = parent.queryColumns(for: tab)
                let filters = filtered ? tab.filterState.appliedFilters : []
                let logicMode = tab.filterState.filterLogicMode
                let sql = parent.queryBuilder.buildFilteredCountQuery(
                    tableName: tableName,
                    schemaName: tab.tableContext.schemaName,
                    filters: filters,
                    logicMode: logicMode,
                    columns: queryColumns.columns,
                    columnTypes: queryColumns.columnTypes
                )
                return (plan, ExactCountInput(sql: sql, filters: filters, logicMode: logicMode), scope)
            }

            let outcome = await Self.rowCountOutcome(
                plan: prepared.plan,
                count: prepared.count,
                scope: prepared.scope,
                tableName: tableName
            )

            await MainActor.run {
                // Clears the running flag on every exit, but only for the slot's owner, or a superseded task releases its successor.
                let ownsCount = parent.clearRowCountTask(for: tabId, token: token)
                let isCurrent = parent.tabExecution.isSameContent(contentEpoch, for: tabId)
                parent.tabManager.mutate(tabId: tabId) { tab in
                    if ownsCount {
                        tab.pagination.isCountPending = false
                    }
                    guard isCurrent, let applied = outcome?.appliedTotal else { return }
                    tab.pagination.applyDerivedRowCount(applied.total, isApproximate: applied.isApproximate)
                }
            }
        }
        parent.setRowCountTask(task, token: token, for: tabId)
    }

    // Split out so `resolveRowCount` has one exit that clears `isCountPending`.
    private static func rowCountOutcome(
        plan: RowCountPlan,
        count exactCount: ExactCountInput?,
        scope: DatabaseScope?,
        tableName: String
    ) async -> RowCountOutcome? {
        guard let scope else { return nil }

        switch plan {
        case .skip:
            return nil
        case .clear:
            return .clear
        case .approximate:
            guard let count = try? await DatabaseManager.shared.withMetadataDriver(scope: scope, { driver in
                try await driver.fetchApproximateRowCount(table: tableName, schema: scope.schema)
            }) else { return nil }
            return .count(count, isApproximate: true)
        case let .filteredNonSQL(filters, logicMode):
            guard let count = try? await DatabaseManager.shared.withRowCountDriver(scope: scope, filtered: true, { driver in
                try await driver.fetchFilteredRowCount(table: tableName, filters: filters, logicMode: logicMode)
            }) else { return .clear }
            return .count(count, isApproximate: false)
        case let .browseSearch(search, tableSizeLimit):
            do {
                let count = try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: .bulk) { driver in
                    try await ExactRowCounter.countBrowseSearch(
                        on: driver, table: tableName, search: search, tableSizeLimit: tableSizeLimit
                    )
                }
                return count.map { RowCountOutcome.count($0, isApproximate: false) }
            } catch {
                helpersLogger.warning("Browse search count failed for \(tableName): \(error.localizedDescription)")
                return nil
            }
        case .exactCount:
            guard let exactCount, let sql = exactCount.sql else { return nil }
            do {
                let count = try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: .bulk) { driver in
                    try await ExactRowCounter.count(
                        on: driver,
                        table: tableName,
                        filters: exactCount.filters,
                        logicMode: exactCount.logicMode,
                        countSQL: sql
                    )
                }
                return count.map { RowCountOutcome.count($0, isApproximate: false) }
            } catch {
                helpersLogger.warning("COUNT query failed for \(tableName): \(error.localizedDescription)")
                return nil
            }
        }
    }

    // A browse search never takes the table estimate (it covers the whole database); not clearing keeps Count Exactly across pages.
    static func rowCountPlan(
        isNonSQL: Bool,
        filterState: TabFilterState,
        approximateRowCount: Int?,
        threshold: Int,
        countsAutomatically: Bool = true,
        browseSearch: BrowseSearchState? = nil
    ) -> RowCountPlan {
        if let browseSearch {
            return countsAutomatically ? .browseSearch(browseSearch, tableSizeLimit: threshold) : .skip
        }
        guard countsAutomatically else {
            return filterState.hasAppliedFilters ? .clear : .skip
        }
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

    // The caller settles the window's task handle and spinner before this runs, so nothing here touches them.
    func handleQueryExecutionError(
        _ error: Error,
        sql: String,
        tabId: UUID,
        connection conn: DatabaseConnection,
        serverOutput: PluginServerOutput = .none
    ) {
        let diagnosis = DatabaseWriteRejectionDiagnosis.formatted(error)
        let message = ServerOutputCapture.failureMessage(diagnosis, output: serverOutput)
        helpersLogger.error(
            "Query failed on tab \(tabId, privacy: .public): \(error.publicLogShape, privacy: .public)"
        )
        presentTabFailure(message, announcing: diagnosis, onTab: tabId) { tab in
            tab.execution.errorQuery = sql
            tab.execution.lastExecutedAt = Date()
            tab.execution.executionTime = nil
        }

        recordHistory(
            QueryHistoryRecordRequest(
                query: sql,
                connectionId: conn.id,
                databaseName: historyDatabaseName(tabId: tabId),
                databaseType: conn.type,
                schemaName: historySchemaName(tabId: tabId),
                source: historySource(tabId: tabId),
                executionTime: 0,
                rowCount: -1,
                wasSuccessful: false,
                errorMessage: error.localizedDescription
            )
        )
    }
}

extension QueryExecutionCoordinator {
    // Records no history: a step failing before the tab's query (such as the database switch) leaves nothing for Fix with AI.
    func presentTabFailure(
        _ message: String,
        announcing diagnosis: String,
        onTab tabId: UUID,
        recordingExecution: (inout QueryTab) -> Void = { _ in }
    ) {
        parent.tabManager.mutate(tabId: tabId) { tab in
            tab.execution.errorMessage = message
            tab.pagination.isLoading = false
            recordingExecution(&tab)

            // The error banner sits at the top of the results pane, so a collapsed pane would hide the only sign the query failed.
            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }
        }
        // The toolbar mirrors the selected tab, so a background tab's failure leaves the window chrome alone.
        if parent.tabManager.selectedTabId == tabId {
            parent.toolbarState.isResultsCollapsed = false
            parent.toolbarState.clearQueryTiming(forTab: tabId)
            parent.announceQueryError(diagnosis)
        }
    }
}

internal struct ExactCountInput: Sendable {
    internal let sql: String?
    internal let filters: [TableFilter]
    internal let logicMode: FilterLogicMode
}

enum RowCountPlan: Equatable {
    case skip
    case clear
    case approximate
    case browseSearch(BrowseSearchState, tableSizeLimit: Int)
    case exactCount(filtered: Bool)
    case filteredNonSQL(filters: [TableFilter], logicMode: FilterLogicMode)
}

enum RowCountOutcome: Equatable {
    case count(Int, isApproximate: Bool)
    case clear

    // Nil is no answer, not zero: an estimate <= 0 is unknown (un-analyzed tables report 0 or -1), so phase 1's estimate stays.
    var appliedTotal: (total: Int?, isApproximate: Bool)? {
        switch self {
        case .clear:
            return (nil, false)
        case let .count(value, isApproximate):
            guard value > 0 || (value == 0 && !isApproximate) else { return nil }
            return (value, isApproximate)
        }
    }
}
