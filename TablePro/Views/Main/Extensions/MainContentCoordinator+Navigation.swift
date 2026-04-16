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

        // Get current database name from active session (may differ from connection default after Cmd+K switch)
        let currentDatabase: String
        if navigationModel == .inPlace {
            // In-place navigation: extract db index from table name "db3" → "3"
            guard tableName.hasPrefix("db"), Int(String(tableName.dropFirst(2))) != nil else {
                return
            }
            currentDatabase = String(tableName.dropFirst(2))
        } else if let session = DatabaseManager.shared.session(for: connectionId) {
            currentDatabase = session.activeDatabase
        } else {
            currentDatabase = connection.database
        }

        let currentSchema = DatabaseManager.shared.session(for: connectionId)?.currentSchema

        // Fast path: if this table is already the active tab in the same database, skip all work
        if let current = tabManager.selectedTab,
           current.tabType == .table,
           current.tableName == tableName,
           current.databaseName == currentDatabase {
            if showStructure, let idx = tabManager.selectedTabIndex {
                tabManager.tabs[idx].showStructure = true
            }
            return
        }

        // During database switch, update the existing tab in-place instead of
        // opening a new in-app tab.
        if sidebarLoadingState == .loading {
            if tabManager.tabs.isEmpty {
                tabManager.addTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase
                )
            }
            return
        }

        // Check if another in-app tab already has this table open — switch to it
        if let existingTab = tabManager.tabs.first(where: {
            $0.tabType == .table && $0.tableName == tableName && $0.databaseName == currentDatabase
        }) {
            tabManager.selectedTabId = existingTab.id
            return
        }

        // If no tabs exist (empty state), add a table tab directly.
        // In preview mode, mark it as preview so subsequent clicks replace it.
        if tabManager.tabs.isEmpty {
            if AppSettingsManager.shared.tabs.enablePreviewTabs {
                tabManager.addPreviewTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase
                )
                contentWindow?.subtitle = "\(connection.name) — Preview"
            } else {
                tabManager.addTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase
                )
            }
            if let tabIndex = tabManager.selectedTabIndex {
                tabManager.tabs[tabIndex].isView = isView
                tabManager.tabs[tabIndex].isEditable = !isView
                tabManager.tabs[tabIndex].schemaName = currentSchema
                tabManager.tabs[tabIndex].pagination.reset()
                toolbarState.isTableTab = true
            }
            // In-place navigation needs selectRedisDatabaseAndQuery to ensure the correct
            // database is SELECTed and session state is updated before querying.
            restoreColumnLayoutForTable(tableName)
            restoreFiltersForTable(tableName)
            if navigationModel == .inPlace, let dbIndex = Int(currentDatabase) {
                selectRedisDatabaseAndQuery(dbIndex)
            } else {
                runQuery()
            }
            return
        }

        // In-place navigation: replace current tab content rather than
        // opening new in-app tabs (e.g. Redis database switching).
        if navigationModel == .inPlace {
            if let oldTab = tabManager.selectedTab, let oldTableName = oldTab.tableName {
                filterStateManager.saveLastFilters(for: oldTableName)
            }
            if tabManager.replaceTabContent(
                tableName: tableName,
                databaseType: connection.type,
                databaseName: currentDatabase,
                schemaName: currentSchema
            ) {
                filterStateManager.clearAll()
                if let tabIndex = tabManager.selectedTabIndex {
                    tabManager.tabs[tabIndex].pagination.reset()
                    toolbarState.isTableTab = true
                }
                restoreColumnLayoutForTable(tableName)
                restoreFiltersForTable(tableName)
                if let dbIndex = Int(currentDatabase) {
                    selectRedisDatabaseAndQuery(dbIndex)
                }
            }
            return
        }

        // If current tab has unsaved changes, active filters, or sorting, open in a new in-app tab
        let hasActiveWork = changeManager.hasChanges
            || filterStateManager.hasAppliedFilters
            || (tabManager.selectedTab?.sortState.isSorting ?? false)
        if hasActiveWork {
            addTableTabInApp(
                tableName: tableName,
                databaseName: currentDatabase,
                schemaName: currentSchema,
                isView: isView,
                showStructure: showStructure
            )
            return
        }

        // Preview tab mode: reuse or create a preview tab instead of a new native window
        if AppSettingsManager.shared.tabs.enablePreviewTabs {
            openPreviewTab(tableName, isView: isView, databaseName: currentDatabase, schemaName: currentSchema, showStructure: showStructure)
            return
        }

        // Default: open table in a new in-app tab
        addTableTabInApp(
            tableName: tableName,
            databaseName: currentDatabase,
            schemaName: currentSchema,
            isView: isView,
            showStructure: showStructure
        )
    }

    /// Helper: add a table tab in-app and execute its query
    private func addTableTabInApp(
        tableName: String,
        databaseName: String,
        schemaName: String?,
        isView: Bool = false,
        showStructure: Bool = false
    ) {
        tabManager.addTableTab(
            tableName: tableName,
            databaseType: connection.type,
            databaseName: databaseName
        )
        if let tabIndex = tabManager.selectedTabIndex {
            tabManager.tabs[tabIndex].isView = isView
            tabManager.tabs[tabIndex].isEditable = !isView
            tabManager.tabs[tabIndex].schemaName = schemaName
            if showStructure {
                tabManager.tabs[tabIndex].showStructure = true
            }
            tabManager.tabs[tabIndex].pagination.reset()
            toolbarState.isTableTab = true
        }
        restoreColumnLayoutForTable(tableName)
        restoreFiltersForTable(tableName)
        // Query execution is deferred to scheduleTabSwitch Phase 2, which detects
        // needsLazyQuery (rows empty, never executed) and runs the query only when
        // the user actually settles on this tab. This prevents the double-query
        // pattern where addTableTabInApp starts a query that gets immediately
        // cancelled by the next tab's creation bumping queryGeneration.
    }

    // MARK: - Preview Tabs

    func openPreviewTab(
        _ tableName: String, isView: Bool = false,
        databaseName: String = "", schemaName: String? = nil,
        showStructure: Bool = false
    ) {
        // Check if a preview tab already exists in this window's tab manager
        if let previewIndex = tabManager.tabs.firstIndex(where: { $0.isPreview }) {
            let previewTab = tabManager.tabs[previewIndex]
            // Skip if preview tab already shows this table
            if previewTab.tableName == tableName, previewTab.databaseName == databaseName {
                tabManager.selectedTabId = previewTab.id
                return
            }
            // Preview tab has unsaved changes — promote it and open a new tab instead
            if previewTab.pendingChanges.hasChanges || previewTab.isFileDirty {
                tabManager.tabs[previewIndex].isPreview = false
                contentWindow?.subtitle = connection.name
                addTableTabInApp(
                    tableName: tableName,
                    databaseName: databaseName,
                    schemaName: schemaName,
                    isView: isView,
                    showStructure: showStructure
                )
                return
            }
            if let oldTableName = previewTab.tableName {
                filterStateManager.saveLastFilters(for: oldTableName)
            }
            // Select the preview tab first so replaceTabContent operates on it
            tabManager.selectedTabId = previewTab.id
            tabManager.replaceTabContent(
                tableName: tableName,
                databaseType: connection.type,
                isView: isView,
                databaseName: databaseName,
                schemaName: schemaName,
                isPreview: true
            )
            filterStateManager.clearAll()
            if let tabIndex = tabManager.selectedTabIndex {
                tabManager.tabs[tabIndex].showStructure = showStructure
                tabManager.tabs[tabIndex].pagination.reset()
                toolbarState.isTableTab = true
            }
            restoreColumnLayoutForTable(tableName)
            restoreFiltersForTable(tableName)
            runQuery()
            return
        }

        // No preview tab exists but current tab can be reused: replace in-place.
        // This covers: non-preview table tabs with no active work,
        // and empty/default query tabs (no user-entered content).
        let isReusableTab: Bool = {
            guard let tab = tabManager.selectedTab else { return false }
            // Table tab with no active work
            if tab.tabType == .table && !changeManager.hasChanges
                && !filterStateManager.hasAppliedFilters && !tab.sortState.isSorting {
                return true
            }
            // Empty/default query tab (no user content, no results, never executed)
            if tab.tabType == .query && tab.lastExecutedAt == nil
                && tab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return false
        }()
        if let selectedTab = tabManager.selectedTab, isReusableTab {
            // Skip if already showing this table
            if selectedTab.tableName == tableName, selectedTab.databaseName == databaseName {
                return
            }
            // If reusable tab has active work, promote it and open new tab instead
            let hasUnsavedQuery = tabManager.selectedTab.map { tab in
                tab.tabType == .query && !tab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? false
            let previewHasWork = changeManager.hasChanges
                || filterStateManager.hasAppliedFilters
                || selectedTab.sortState.isSorting
                || hasUnsavedQuery
            if previewHasWork {
                promotePreviewTab()
                addTableTabInApp(
                    tableName: tableName,
                    databaseName: databaseName,
                    schemaName: schemaName,
                    isView: isView,
                    showStructure: showStructure
                )
                return
            }
            if let oldTableName = selectedTab.tableName {
                filterStateManager.saveLastFilters(for: oldTableName)
            }
            tabManager.replaceTabContent(
                tableName: tableName,
                databaseType: connection.type,
                isView: isView,
                databaseName: databaseName,
                schemaName: schemaName,
                isPreview: true
            )
            filterStateManager.clearAll()
            if let tabIndex = tabManager.selectedTabIndex {
                tabManager.tabs[tabIndex].showStructure = showStructure
                tabManager.tabs[tabIndex].pagination.reset()
                toolbarState.isTableTab = true
            }
            restoreColumnLayoutForTable(tableName)
            restoreFiltersForTable(tableName)
            runQuery()
            return
        }

        // No reusable tab: create a new in-app preview tab
        tabManager.addPreviewTableTab(
            tableName: tableName,
            databaseType: connection.type,
            databaseName: databaseName
        )
        contentWindow?.subtitle = "\(connection.name) — Preview"
        if let tabIndex = tabManager.selectedTabIndex {
            tabManager.tabs[tabIndex].isView = isView
            tabManager.tabs[tabIndex].isEditable = !isView
            tabManager.tabs[tabIndex].schemaName = schemaName
            if showStructure {
                tabManager.tabs[tabIndex].showStructure = true
            }
            tabManager.tabs[tabIndex].pagination.reset()
            toolbarState.isTableTab = true
        }
        restoreColumnLayoutForTable(tableName)
        restoreFiltersForTable(tableName)
        runQuery()
    }

    func promotePreviewTab() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabManager.tabs[tabIndex].isPreview else { return }
        tabManager.tabs[tabIndex].isPreview = false
        contentWindow?.subtitle = connection.name
    }

    func showAllTablesMetadata() {
        guard let sql = allTablesMetadataSQL() else { return }
        tabManager.addTab(initialQuery: sql, databaseName: connection.database)
        runQuery()
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
                databaseName: connection.database
            )
            runQuery()
            return nil
        } else if editorLang == .bash {
            tabManager.addTab(
                initialQuery: "SCAN 0 MATCH * COUNT 100",
                databaseName: connection.database
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
        sidebarLoadingState = .loading

        filterStateManager.clearAll()

        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            sidebarLoadingState = .error(String(localized: "Not connected"))
            return
        }

        let previousDatabase = toolbarState.databaseName

        toolbarState.databaseName = database
        persistence.saveNowSync(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
        tabManager.tabs = []
        tabManager.selectedTabId = nil
        DatabaseManager.shared.updateSession(connectionId) { session in
            session.tables = []
        }

        do {
            let pm = PluginManager.shared
            if pm.requiresReconnectForDatabaseSwitch(for: connection.type) {
                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.connection.database = database
                    session.currentDatabase = database
                    session.currentSchema = nil
                }
                AppSettingsStorage.shared.saveLastSchema(nil, for: connectionId)
                await DatabaseManager.shared.reconnectSession(connectionId)
            } else if pm.supportsSchemaSwitching(for: connection.type) {
                guard let schemaDriver = driver as? SchemaSwitchable else {
                    sidebarLoadingState = .idle
                    return
                }
                try await schemaDriver.switchSchema(to: database)
                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentSchema = database
                }
            } else {
                if let adapter = driver as? PluginDriverAdapter {
                    try await adapter.switchDatabase(to: database)
                }
                let grouping = pm.databaseGroupingStrategy(for: connection.type)
                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentDatabase = database
                    if grouping == .bySchema {
                        session.currentSchema = pm.defaultSchemaName(for: connection.type)
                    }
                }
            }
            AppSettingsStorage.shared.saveLastDatabase(database, for: connectionId)
            await refreshTables()
        } catch {
            toolbarState.databaseName = previousDatabase
            sidebarLoadingState = .error(error.localizedDescription)

            navigationLogger.error("Failed to switch database: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Database Switch Failed"),
                message: error.localizedDescription,
                window: contentWindow
            )
        }
    }

    /// Switch to a different PostgreSQL schema (used for URL-based schema selection)
    func switchSchema(to schema: String) async {
        guard PluginManager.shared.supportsSchemaSwitching(for: connection.type) else { return }
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }

        sidebarLoadingState = .loading
        filterStateManager.clearAll()

        let previousSchema = toolbarState.databaseName

        toolbarState.databaseName = schema
        persistence.saveNowSync(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
        tabManager.tabs = []
        tabManager.selectedTabId = nil
        DatabaseManager.shared.updateSession(connectionId) { session in
            session.tables = []
        }

        do {
            guard let schemaDriver = driver as? SchemaSwitchable else {
                sidebarLoadingState = .idle
                return
            }
            try await schemaDriver.switchSchema(to: schema)

            DatabaseManager.shared.updateSession(connectionId) { session in
                session.currentSchema = schema
            }
            AppSettingsStorage.shared.saveLastSchema(schema, for: connectionId)

            await refreshTables()
        } catch {
            toolbarState.databaseName = previousSchema
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
        redisDatabaseSwitchTask = Task { @MainActor [weak self] in
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
            toolbarState.databaseName = database
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
        let database = toolbarState.databaseName
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
