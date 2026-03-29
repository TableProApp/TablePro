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
        // opening a new native window tab.
        if isSwitchingDatabase {
            if tabManager.tabs.isEmpty {
                tabManager.addTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase
                )
            }
            return
        }

        // Check if another native window tab already has this table open — switch to it
        if let keyWindow = NSApp.keyWindow {
            let tabbedWindows = keyWindow.tabbedWindows ?? [keyWindow]
            for window in tabbedWindows where window.title == tableName {
                window.makeKeyAndOrderFront(nil)
                return
            }
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
                if let wid = windowId {
                    WindowLifecycleMonitor.shared.setPreview(true, for: wid)
                    WindowLifecycleMonitor.shared.window(for: wid)?.subtitle = "\(connection.name) — Preview"
                }
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
                tabManager.tabs[tabIndex].pagination.reset()
                AppState.shared.isCurrentTabEditable = !isView && tableName.isEmpty == false
                toolbarState.isTableTab = true
                AppState.shared.isTableTab = true
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
        // opening new native window tabs (e.g. Redis database switching).
        if navigationModel == .inPlace {
            if let oldTab = tabManager.selectedTab, let oldTableName = oldTab.tableName {
                filterStateManager.saveLastFilters(for: oldTableName)
            }
            if tabManager.replaceTabContent(
                tableName: tableName,
                databaseType: connection.type,
                databaseName: currentDatabase
            ) {
                filterStateManager.clearAll()
                if let tabIndex = tabManager.selectedTabIndex {
                    tabManager.tabs[tabIndex].pagination.reset()
                    toolbarState.isTableTab = true
                AppState.shared.isTableTab = true
                }
                restoreColumnLayoutForTable(tableName)
                restoreFiltersForTable(tableName)
                if let dbIndex = Int(currentDatabase) {
                    selectRedisDatabaseAndQuery(dbIndex)
                }
            }
            return
        }

        // If current tab has unsaved changes, active filters, or sorting, open in a new native tab
        let hasActiveWork = changeManager.hasChanges
            || filterStateManager.hasAppliedFilters
            || (tabManager.selectedTab?.sortState.isSorting ?? false)
        if hasActiveWork {
            let payload = EditorTabPayload(
                connectionId: connection.id,
                tabType: .table,
                tableName: tableName,
                databaseName: currentDatabase,
                isView: isView,
                showStructure: showStructure
            )
            WindowOpener.shared.openNativeTab(payload)
            return
        }

        // Preview tab mode: reuse or create a preview tab instead of a new native window
        if AppSettingsManager.shared.tabs.enablePreviewTabs {
            openPreviewTab(tableName, isView: isView, databaseName: currentDatabase, showStructure: showStructure)
            return
        }

        // Default: open table in a new native tab
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .table,
            tableName: tableName,
            databaseName: currentDatabase,
            isView: isView,
            showStructure: showStructure
        )
        WindowOpener.shared.openNativeTab(payload)
    }

    // MARK: - Preview Tabs

    func openPreviewTab(
        _ tableName: String, isView: Bool = false,
        databaseName: String = "", showStructure: Bool = false
    ) {
        // Check if a preview window already exists for this connection
        if let preview = WindowLifecycleMonitor.shared.previewWindow(for: connectionId) {
            if let previewCoordinator = Self.coordinator(for: preview.windowId) {
                // Skip if preview tab already shows this table
                if let current = previewCoordinator.tabManager.selectedTab,
                   current.tableName == tableName,
                   current.databaseName == databaseName {
                    preview.window.makeKeyAndOrderFront(nil)
                    return
                }
                if let oldTab = previewCoordinator.tabManager.selectedTab,
                   let oldTableName = oldTab.tableName {
                    previewCoordinator.filterStateManager.saveLastFilters(for: oldTableName)
                }
                previewCoordinator.tabManager.replaceTabContent(
                    tableName: tableName,
                    databaseType: connection.type,
                    isView: isView,
                    databaseName: databaseName,
                    isPreview: true
                )
                previewCoordinator.filterStateManager.clearAll()
                if let tabIndex = previewCoordinator.tabManager.selectedTabIndex {
                    previewCoordinator.tabManager.tabs[tabIndex].showStructure = showStructure
                    previewCoordinator.tabManager.tabs[tabIndex].pagination.reset()
                    AppState.shared.isCurrentTabEditable = !isView && !tableName.isEmpty
                    previewCoordinator.toolbarState.isTableTab = true
                    AppState.shared.isTableTab = true
                }
                preview.window.makeKeyAndOrderFront(nil)
                previewCoordinator.restoreColumnLayoutForTable(tableName)
                previewCoordinator.restoreFiltersForTable(tableName)
                previewCoordinator.runQuery()
                return
            }
        }

        // No preview window exists but current tab is already a preview: replace in-place
        if let selectedTab = tabManager.selectedTab, selectedTab.isPreview {
            // Skip if already showing this table
            if selectedTab.tableName == tableName, selectedTab.databaseName == databaseName {
                return
            }
            // If preview tab has active work, promote it and open new tab instead
            let previewHasWork = changeManager.hasChanges
                || filterStateManager.hasAppliedFilters
                || selectedTab.sortState.isSorting
            if previewHasWork {
                promotePreviewTab()
                let payload = EditorTabPayload(
                    connectionId: connection.id,
                    tabType: .table,
                    tableName: tableName,
                    databaseName: databaseName,
                    isView: isView,
                    showStructure: showStructure
                )
                WindowOpener.shared.openNativeTab(payload)
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
                isPreview: true
            )
            filterStateManager.clearAll()
            if let tabIndex = tabManager.selectedTabIndex {
                tabManager.tabs[tabIndex].showStructure = showStructure
                tabManager.tabs[tabIndex].pagination.reset()
                AppState.shared.isCurrentTabEditable = !isView && !tableName.isEmpty
                toolbarState.isTableTab = true
                AppState.shared.isTableTab = true
            }
            restoreColumnLayoutForTable(tableName)
            restoreFiltersForTable(tableName)
            runQuery()
            return
        }

        // No preview tab anywhere: create a new native preview tab
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .table,
            tableName: tableName,
            databaseName: databaseName,
            isView: isView,
            showStructure: showStructure,
            isPreview: true
        )
        WindowOpener.shared.openNativeTab(payload)
    }

    func promotePreviewTab() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabManager.tabs[tabIndex].isPreview else { return }
        tabManager.tabs[tabIndex].isPreview = false

        if let wid = windowId {
            WindowLifecycleMonitor.shared.setPreview(false, for: wid)
            WindowLifecycleMonitor.shared.window(for: wid)?.subtitle = connection.name
        }
    }

    func showAllTablesMetadata() {
        guard let sql = allTablesMetadataSQL() else { return }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            initialQuery: sql
        )
        WindowOpener.shared.openNativeTab(payload)
    }

    private func currentSchemaName(fallback: String) -> String {
        if let schemaDriver = DatabaseManager.shared.driver(for: connectionId) as? SchemaSwitchable {
            return schemaDriver.escapedSchema
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

    /// Close all sibling native window-tabs except the current key window.
    /// Each table opened via WindowOpener creates a separate NSWindow in the same
    /// tab group. Clearing `tabManager.tabs` only affects the in-app state of the
    /// *current* window — other NSWindows remain open with stale content.
    private func closeSiblingNativeWindows() {
        guard let keyWindow = NSApp.keyWindow else { return }
        let siblings = keyWindow.tabbedWindows ?? []
        for sibling in siblings where sibling !== keyWindow {
            sibling.close()
        }
    }

    /// Switch to a different database (called from database switcher)
    func switchDatabase(to database: String) async {
        isSwitchingDatabase = true
        defer {
            isSwitchingDatabase = false
        }

        // Clear stale filter state from previous database/schema
        filterStateManager.clearAll()

        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            return
        }

        // Snapshot current state for rollback on failure
        let previousDatabase = toolbarState.databaseName

        // Immediately clear UI state so the sidebar shows a loading spinner
        // instead of stale tables from the previous database/schema.
        toolbarState.databaseName = database
        closeSiblingNativeWindows()
        tabManager.tabs = []
        tabManager.selectedTabId = nil
        DatabaseManager.shared.updateSession(connectionId) { session in
            session.tables = []
        }
        // Yield so SwiftUI renders the empty/loading state before async work begins
        await Task.yield()

        do {
            let pm = PluginManager.shared
            if pm.requiresReconnectForDatabaseSwitch(for: connection.type) {
                // PostgreSQL: full reconnection required for database switch
                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.connection.database = database
                    session.currentDatabase = database
                    session.currentSchema = nil
                }
                await DatabaseManager.shared.reconnectSession(connectionId)
            } else if pm.supportsSchemaSwitching(for: connection.type) {
                // Redshift, Oracle: schema switching
                guard let schemaDriver = driver as? SchemaSwitchable else { return }
                try await schemaDriver.switchSchema(to: database)
                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentSchema = database
                }
            } else {
                // All others (MySQL, MariaDB, ClickHouse, MSSQL, MongoDB, Redis, etc.)
                if let adapter = driver as? PluginDriverAdapter {
                    try await adapter.switchDatabase(to: database)
                }
                let grouping = pm.databaseGroupingStrategy(for: connection.type)
                DatabaseManager.shared.updateSession(connectionId) { session in
                    session.currentDatabase = database
                    // Schema-grouped databases (e.g. MSSQL) need currentSchema
                    // reset to the plugin default (e.g. "dbo") on database switch.
                    if grouping == .bySchema {
                        session.currentSchema = pm.defaultSchemaName(for: connection.type)
                    }
                }
            }
            AppSettingsStorage.shared.saveLastDatabase(database, for: connectionId)
            await loadSchema()
            reloadSidebar()
        } catch {
            // Restore toolbar to previous database on failure
            toolbarState.databaseName = previousDatabase
            // Reload previous tables so sidebar isn't left empty
            reloadSidebar()

            navigationLogger.error("Failed to switch database: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Database Switch Failed"),
                message: error.localizedDescription,
                window: NSApplication.shared.keyWindow
            )
        }
    }

    /// Switch to a different PostgreSQL schema (used for URL-based schema selection)
    func switchSchema(to schema: String) async {
        guard PluginManager.shared.supportsSchemaSwitching(for: connection.type) else { return }
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }

        // Clear stale filter state from previous schema
        filterStateManager.clearAll()

        // Snapshot current state for rollback on failure
        let previousSchema = toolbarState.databaseName

        // Immediately clear UI state so sidebar shows loading state
        toolbarState.databaseName = schema
        closeSiblingNativeWindows()
        tabManager.tabs = []
        tabManager.selectedTabId = nil
        DatabaseManager.shared.updateSession(connectionId) { session in
            session.tables = []
        }
        await Task.yield()

        do {
            guard let schemaDriver = driver as? SchemaSwitchable else { return }
            try await schemaDriver.switchSchema(to: schema)

            DatabaseManager.shared.updateSession(connectionId) { session in
                session.currentSchema = schema
            }

            await loadSchema()

            reloadSidebar()
        } catch {
            // Restore toolbar to previous schema on failure
            toolbarState.databaseName = previousSchema
            reloadSidebar()

            navigationLogger.error("Failed to switch schema: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Schema Switch Failed"),
                message: error.localizedDescription,
                window: NSApplication.shared.keyWindow
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
