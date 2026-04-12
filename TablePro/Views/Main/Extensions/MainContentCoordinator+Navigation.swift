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

    func openTableTab(_ tableName: String, showStructure: Bool = false, isView: Bool = false, forceNewTab: Bool = false) {
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
        // opening a new native window tab.
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

        // Check if another native window tab already has this table open — switch to it
        if let keyWindow = NSApp.keyWindow {
            let ownWindows = Set(WindowLifecycleMonitor.shared.windows(for: connectionId).map { ObjectIdentifier($0) })
            let tabbedWindows = keyWindow.tabbedWindows ?? [keyWindow]
            for window in tabbedWindows
                where window.title == tableName && ownWindows.contains(ObjectIdentifier(window)) {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }

        // If no tabs exist (empty state), add a table tab directly.
        if tabManager.tabs.isEmpty {
            tabManager.addTableTab(
                tableName: tableName,
                databaseType: connection.type,
                databaseName: currentDatabase
            )
            if let tabIndex = tabManager.selectedTabIndex {
                tabManager.tabs[tabIndex].isView = isView
                tabManager.tabs[tabIndex].isEditable = !isView
                tabManager.tabs[tabIndex].schemaName = currentSchema
                tabManager.tabs[tabIndex].showStructure = showStructure
                tabManager.tabs[tabIndex].pagination.reset()
                toolbarState.isTableTab = true
            }
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

        // If current tab has unsaved changes, active filters, or sorting, open in a new native tab
        let hasActiveWork = changeManager.hasChanges
            || filterStateManager.hasAppliedFilters
            || (tabManager.selectedTab?.sortState.isSorting ?? false)

        // When not forced to new tab: replace current table tab in-place if it has no active work
        if !forceNewTab && !hasActiveWork,
           let currentTab = tabManager.selectedTab,
           currentTab.tabType == .table {
            if let oldTableName = currentTab.tableName {
                filterStateManager.saveLastFilters(for: oldTableName)
            }
            tabManager.replaceTabContent(
                tableName: tableName,
                databaseType: connection.type,
                isView: isView,
                databaseName: currentDatabase,
                schemaName: currentSchema
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

        // Open table in a new native tab (Cmd+Click, active work, or current tab is not a table)
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .table,
            tableName: tableName,
            databaseName: currentDatabase,
            schemaName: currentSchema,
            isView: isView,
            showStructure: showStructure
        )
        WindowOpener.shared.openNativeTab(payload)
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

    /// Close all sibling native window-tabs except the current key window.
    /// Each table opened via WindowOpener creates a separate NSWindow in the same
    /// tab group. Clearing `tabManager.tabs` only affects the in-app state of the
    /// *current* window — other NSWindows remain open with stale content.
    private func closeSiblingNativeWindows() {
        guard let keyWindow = NSApp.keyWindow else { return }
        let siblings = keyWindow.tabbedWindows ?? []
        let ownWindows = Set(WindowLifecycleMonitor.shared.windows(for: connectionId).map { ObjectIdentifier($0) })
        for sibling in siblings where sibling !== keyWindow {
            // Only close windows belonging to this connection to avoid
            // destroying tabs from other connections when groupAllConnectionTabs is ON
            guard ownWindows.contains(ObjectIdentifier(sibling)) else { continue }
            sibling.close()
        }
    }

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
        closeSiblingNativeWindows()
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
        closeSiblingNativeWindows()
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
