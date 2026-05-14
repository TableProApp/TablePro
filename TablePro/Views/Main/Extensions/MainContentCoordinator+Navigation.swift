//
//  MainContentCoordinator+Navigation.swift
//  TablePro
//
//  Table tab opening and database switching operations for MainContentCoordinator
//

import AppKit
import Foundation
import os
import TableProPluginKit

private let navigationLogger = Logger(subsystem: "com.TablePro", category: "MainContentCoordinator+Navigation")

extension MainContentCoordinator {
    // MARK: - Table Tab Opening

    func openTableTab(_ tableName: String, showStructure: Bool = false, isView: Bool = false) {
        let navigationModel = PluginMetadataRegistry.shared.snapshot(
            forTypeId: connection.type.pluginTypeId
        )?.navigationModel ?? .standard

        let currentDatabase: String
        if navigationModel == .inPlace {
            guard tableName.hasPrefix("db"), Int(String(tableName.dropFirst(2))) != nil else {
                return
            }
            currentDatabase = String(tableName.dropFirst(2))
        } else {
            currentDatabase = activeDatabaseName
        }

        let currentSchema = DatabaseManager.shared.session(for: connectionId)?.currentSchema

        // Fast path: if this table is already the active tab in the same database, skip all work
        if let current = tabManager.selectedTab,
           current.tabType == .table,
           current.tableContext.tableName == tableName,
           current.tableContext.databaseName == currentDatabase {
            if showStructure, let (_, tabIndex) = tabManager.selectedTabAndIndex {
                tabManager.mutate(at: tabIndex) { $0.display.resultsViewMode = .structure }
            }
            return
        }

        // During database switch, update the existing tab in-place instead of
        // opening a new native window tab.
        if case .loading = SchemaService.shared.state(for: connectionId) {
            if tabManager.tabs.isEmpty {
                do {
                    try tabManager.addTableTab(
                        tableName: tableName,
                        databaseType: connection.type,
                        databaseName: currentDatabase
                    )
                } catch {
                    navigationLogger.error("openTableTab addTableTab failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        if let existing = tabManager.tabs.first(where: { tab in
            tab.tabType == .table
                && !tab.isPreview
                && tab.tableContext.tableName == tableName
                && tab.tableContext.databaseName == currentDatabase
        }) {
            tabManager.selectTab(id: existing.id)
            if showStructure, let index = tabManager.selectedTabIndex {
                tabManager.mutate(at: index) { $0.display.resultsViewMode = .structure }
            }
            return
        }

        // If no tabs exist (empty state), add a table tab directly.
        // In preview mode, mark it as preview so subsequent clicks replace it.
        if tabManager.tabs.isEmpty {
            do {
                if AppSettingsManager.shared.tabs.enablePreviewTabs {
                    try tabManager.addPreviewTableTab(
                        tableName: tableName,
                        databaseType: connection.type,
                        databaseName: currentDatabase
                    )
                } else {
                    try tabManager.addTableTab(
                        tableName: tableName,
                        databaseType: connection.type,
                        databaseName: currentDatabase
                    )
                }
            } catch {
                navigationLogger.error("openTableTab tab creation failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            if let (_, tabIndex) = tabManager.selectedTabAndIndex {
                tabManager.mutate(at: tabIndex) { tab in
                    tab.tableContext.isView = isView
                    tab.tableContext.isEditable = !isView
                    tab.tableContext.schemaName = currentSchema
                    tab.pagination.reset()
                }
                toolbarState.isTableTab = true
            }
            // In-place navigation needs selectRedisDatabaseAndQuery to ensure the correct
            // database is SELECTed and session state is updated before querying.
            restoreLastHiddenColumnsForTable(tableName)
            restoreFiltersForTable(tableName)
            if navigationModel == .inPlace, let dbIndex = Int(currentDatabase) {
                selectRedisDatabaseAndQuery(dbIndex)
            } else {
                runQuery()
            }
            return
        }

        // In-place navigation: replace current tab content rather than
        // opening new native window tabs (e.g. Redis database switching).
        if navigationModel == .inPlace {
            if let oldTab = tabManager.selectedTab, let oldTableName = oldTab.tableContext.tableName {
                saveLastFilters(for: oldTableName)
            }
            do {
                let replaced = try tabManager.replaceTabContent(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase,
                    schemaName: currentSchema
                )
                if replaced {
                    clearFilterState()
                    if let (tab, tabIndex) = tabManager.selectedTabAndIndex {
                        setActiveTableRows(TableRows(), for: tab.id)
                        tabManager.mutate(at: tabIndex) { $0.pagination.reset() }
                        toolbarState.isTableTab = true
                    }
                    restoreLastHiddenColumnsForTable(tableName)
                    restoreFiltersForTable(tableName)
                    if let dbIndex = Int(currentDatabase) {
                        selectRedisDatabaseAndQuery(dbIndex)
                    }
                }
            } catch {
                navigationLogger.error("openTableTab replaceTabContent failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        let hasActiveWork = changeManager.hasChanges
            || selectedTabFilterState.hasAppliedFilters
            || (tabManager.selectedTab?.sortState.isSorting ?? false)
        if hasActiveWork {
            addTableTabAndRun(
                tableName, isView: isView, databaseName: currentDatabase,
                schemaName: currentSchema, showStructure: showStructure
            )
            return
        }

        if AppSettingsManager.shared.tabs.enablePreviewTabs {
            openPreviewTab(tableName, isView: isView, databaseName: currentDatabase, schemaName: currentSchema, showStructure: showStructure)
            return
        }

        addTableTabAndRun(
            tableName, isView: isView, databaseName: currentDatabase,
            schemaName: currentSchema, showStructure: showStructure
        )
    }

    /// Add a new in-window table tab, configure it, and run its query.
    private func addTableTabAndRun(
        _ tableName: String, isView: Bool, databaseName: String,
        schemaName: String?, showStructure: Bool, isPreview: Bool = false
    ) {
        do {
            if isPreview {
                try tabManager.addPreviewTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: databaseName
                )
            } else {
                try tabManager.addTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: databaseName
                )
            }
        } catch {
            navigationLogger.error("addTableTabAndRun failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if let (tab, tabIndex) = tabManager.selectedTabAndIndex {
            setActiveTableRows(TableRows(), for: tab.id)
            tabManager.mutate(at: tabIndex) { mutTab in
                mutTab.tableContext.isView = isView
                mutTab.tableContext.isEditable = !isView
                mutTab.tableContext.schemaName = schemaName
                mutTab.display.resultsViewMode = showStructure ? .structure : .data
                mutTab.pagination.reset()
            }
            toolbarState.isTableTab = true
        }
        clearFilterState()
        restoreLastHiddenColumnsForTable(tableName)
        restoreFiltersForTable(tableName)
        runQuery()
    }

    // MARK: - Preview Tabs

    func openPreviewTab(
        _ tableName: String, isView: Bool = false,
        databaseName: String = "", schemaName: String? = nil,
        showStructure: Bool = false
    ) {
        if let previewIndex = tabManager.tabs.firstIndex(where: { $0.isPreview }) {
            let previewTab = tabManager.tabs[previewIndex]
            tabManager.selectTab(id: previewTab.id)

            if previewTab.tableContext.tableName == tableName,
               previewTab.tableContext.databaseName == databaseName {
                return
            }
            if let oldTableName = previewTab.tableContext.tableName {
                saveLastFilters(for: oldTableName)
            }
            replacePreviewTabContent(
                tableName, isView: isView, databaseName: databaseName,
                schemaName: schemaName, showStructure: showStructure
            )
            return
        }

        let isReusableTab: Bool = {
            guard let tab = tabManager.selectedTab else { return false }
            if tab.tabType == .table && !changeManager.hasChanges
                && !selectedTabFilterState.hasAppliedFilters && !tab.sortState.isSorting {
                return true
            }
            if tab.tabType == .query && tab.execution.lastExecutedAt == nil
                && tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return false
        }()
        if let selectedTab = tabManager.selectedTab, isReusableTab {
            if selectedTab.tableContext.tableName == tableName,
               selectedTab.tableContext.databaseName == databaseName {
                return
            }
            if let oldTableName = selectedTab.tableContext.tableName {
                saveLastFilters(for: oldTableName)
            }
            replacePreviewTabContent(
                tableName, isView: isView, databaseName: databaseName,
                schemaName: schemaName, showStructure: showStructure
            )
            return
        }

        addTableTabAndRun(
            tableName, isView: isView, databaseName: databaseName,
            schemaName: schemaName, showStructure: showStructure, isPreview: true
        )
    }

    /// Replace the currently selected tab's content with a preview table.
    private func replacePreviewTabContent(
        _ tableName: String, isView: Bool, databaseName: String,
        schemaName: String?, showStructure: Bool
    ) {
        do {
            try tabManager.replaceTabContent(
                tableName: tableName,
                databaseType: connection.type,
                isView: isView,
                databaseName: databaseName,
                schemaName: schemaName,
                isPreview: true
            )
        } catch {
            navigationLogger.error("replacePreviewTabContent failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        clearFilterState()
        if let (tab, tabIndex) = tabManager.selectedTabAndIndex {
            setActiveTableRows(TableRows(), for: tab.id)
            tabManager.mutate(at: tabIndex) {
                $0.display.resultsViewMode = showStructure ? .structure : .data
                $0.pagination.reset()
            }
            toolbarState.isTableTab = true
        }
        restoreLastHiddenColumnsForTable(tableName)
        restoreFiltersForTable(tableName)
        runQuery()
    }

    func promotePreviewTab() {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              tab.isPreview else { return }
        tabManager.mutate(at: tabIndex) { $0.isPreview = false }
    }

    func showAllTablesMetadata() {
        guard let sql = allTablesMetadataSQL() else { return }
        tabManager.addTab(initialQuery: sql, databaseName: activeDatabaseName)
    }

    private func currentSchemaName(fallback: String) -> String {
        if let schemaDriver = DatabaseManager.shared.driver(for: connectionId) as? SchemaSwitchable,
           let schema = schemaDriver.escapedSchema {
            return schema
        }
        return fallback
    }

    private func allTablesMetadataSQL() -> String? {
        let editorLang = PluginManager.shared.editorLanguage(for: connection.type)
        // Non-SQL databases: open a command tab instead
        if editorLang == .javascript {
            tabManager.addTab(
                initialQuery: "db.runCommand({\"listCollections\": 1, \"nameOnly\": false})",
                databaseName: activeDatabaseName
            )
            runQuery()
            return nil
        } else if editorLang == .bash {
            tabManager.addTab(
                initialQuery: "SCAN 0 MATCH * COUNT 100",
                databaseName: activeDatabaseName
            )
            runQuery()
            return nil
        }

        // SQL databases: delegate to plugin driver
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return nil }
        let schema = (driver as? SchemaSwitchable)?.escapedSchema
        return (driver as? PluginDriverAdapter)?.allTablesMetadataSQL(schema: schema)
    }

    // MARK: - Database Switching

    /// Switch to a different database (called from database switcher)
    func switchDatabase(to database: String) async {
        clearFilterState()
        let previousDatabase = toolbarState.currentDatabase
        toolbarState.currentDatabase = database

        do {
            try await DatabaseManager.shared.switchDatabase(to: database, for: connectionId)

            persistence.saveNowSync(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
            tabSessionRegistry.removeAll()
            tabManager.tabs = []
            tabManager.selectedTabId = nil
            await SchemaService.shared.invalidate(connectionId: connectionId)

            await refreshTables()
        } catch {
            toolbarState.currentDatabase = previousDatabase

            navigationLogger.error("Failed to switch database: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Database Switch Failed"),
                message: error.localizedDescription,
                window: contentWindow
            )
        }
    }

    func switchSchema(to schema: String) async {
        guard PluginManager.shared.supportsSchemaSwitching(for: connection.type) else {
            navigationLogger.warning(
                "switchSchema(to: \(schema, privacy: .public)) ignored: \(self.connection.type.rawValue, privacy: .public) does not support schema switching"
            )
            AlertHelper.showErrorSheet(
                title: String(localized: "Schema Switching Not Supported"),
                message: String(
                    format: String(localized: "%@ does not support switching schemas in TablePro."),
                    connection.type.rawValue
                ),
                window: contentWindow
            )
            return
        }

        clearFilterState()
        let previousSchema = toolbarState.currentSchema
        toolbarState.currentSchema = schema

        do {
            try await DatabaseManager.shared.switchSchema(to: schema, for: connectionId)

            persistence.saveNowSync(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
            tabSessionRegistry.removeAll()
            tabManager.tabs = []
            tabManager.selectedTabId = nil
            await SchemaService.shared.invalidate(connectionId: connectionId)

            await refreshTables()
        } catch {
            toolbarState.currentSchema = previousSchema
            await refreshTables()

            navigationLogger.error("Failed to switch schema: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Schema Switch Failed"),
                message: error.localizedDescription,
                window: contentWindow
            )
        }
    }

    // MARK: - Redis Database Selection

    /// Select a Redis database index and then run the query.
    /// Redis sidebar clicks go through openTableTab (sync), so we need a Task
    /// to call the async selectDatabase before executing the query.
    /// Cancels any previous in-flight switch to prevent race conditions
    /// from rapid sidebar clicks.
    private func selectRedisDatabaseAndQuery(_ dbIndex: Int) {
        cancelRedisDatabaseSwitchTask()

        let connId = connectionId
        let database = String(dbIndex)
        redisDatabaseSwitchTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let adapter = DatabaseManager.shared.driver(for: connId) as? PluginDriverAdapter {
                    try await adapter.switchDatabase(to: String(dbIndex))
                }
            } catch {
                if !Task.isCancelled {
                    navigationLogger.error("Failed to SELECT Redis db\(dbIndex): \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            guard !Task.isCancelled else { return }
            DatabaseManager.shared.updateSession(connId) { session in
                session.currentDatabase = database
            }
            toolbarState.currentDatabase = database
            executeTableTabQueryDirectly()

            let separator = connection.additionalFields["redisSeparator"] ?? ":"
            if sidebarViewModel?.redisKeyTreeViewModel == nil {
                let vm = RedisKeyTreeViewModel()
                sidebarViewModel?.redisKeyTreeViewModel = vm
                let sidebarState = SharedSidebarState.forConnection(connId)
                sidebarState.redisKeyTreeViewModel = vm
            }
            Task {
                await self.sidebarViewModel?.redisKeyTreeViewModel?.loadKeys(
                    connectionId: connId,
                    database: database,
                    separator: separator
                )
            }
        }
    }

    func initRedisKeyTreeIfNeeded() {
        guard connection.type == .redis else { return }
        let sidebarState = SharedSidebarState.forConnection(connectionId)
        guard sidebarState.redisKeyTreeViewModel == nil else { return }

        let vm = RedisKeyTreeViewModel()
        sidebarState.redisKeyTreeViewModel = vm
        sidebarViewModel?.redisKeyTreeViewModel = vm

        let connId = connectionId
        let database = toolbarState.currentDatabase
        let separator = connection.additionalFields["redisSeparator"] ?? ":"
        Task {
            await vm.loadKeys(connectionId: connId, database: database, separator: separator)
        }
    }

    // MARK: - Redis Key Tree Navigation

    func browseRedisNamespace(_ prefix: String) {
        let separator = connection.additionalFields["redisSeparator"] ?? ":"
        let escapedPrefix = prefix.replacingOccurrences(of: "\"", with: "\\\"")
        let query = "SCAN 0 MATCH \"\(escapedPrefix)*\" COUNT 200"
        let title = prefix.hasSuffix(separator) ? String(prefix.dropLast(separator.count)) : prefix
        tabManager.addTab(initialQuery: query, title: title)
        runQuery()
    }

    func openRedisKey(_ keyName: String, keyType: String) {
        let escapedKey = keyName.replacingOccurrences(of: "\"", with: "\\\"")
        let query: String
        switch keyType.lowercased() {
        case "hash":
            query = "HGETALL \"\(escapedKey)\""
        case "list":
            query = "LRANGE \"\(escapedKey)\" 0 -1"
        case "set":
            query = "SMEMBERS \"\(escapedKey)\""
        case "zset":
            query = "ZRANGE \"\(escapedKey)\" 0 -1 WITHSCORES"
        case "stream":
            query = "XRANGE \"\(escapedKey)\" - +"
        default:
            query = "GET \"\(escapedKey)\""
        }
        tabManager.addTab(initialQuery: query, title: keyName)
        runQuery()
    }
}
