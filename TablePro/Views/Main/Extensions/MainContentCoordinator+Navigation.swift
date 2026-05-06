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
                tabManager.tabs[tabIndex].display.resultsViewMode = .structure
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

        // Check if another native window tab already has this table open — switch to it
        for sibling in MainContentCoordinator.allActiveCoordinators()
            where sibling !== self && sibling.connectionId == connectionId {
            let hasMatch = sibling.tabManager.tabs.contains { tab in
                tab.tabType == .table
                    && tab.tableContext.tableName == tableName
                    && tab.tableContext.databaseName == currentDatabase
            }
            guard hasMatch,
                  let windowId = sibling.windowId,
                  let window = WindowLifecycleMonitor.shared.window(for: windowId) else { continue }
            window.makeKeyAndOrderFront(nil)
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
                    if let wid = windowId {
                        WindowLifecycleMonitor.shared.setPreview(true, for: wid)
                        WindowLifecycleMonitor.shared.window(for: wid)?.subtitle = "\(connection.name) — Preview"
                    }
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
                tabManager.tabs[tabIndex].tableContext.isView = isView
                tabManager.tabs[tabIndex].tableContext.isEditable = !isView
                tabManager.tabs[tabIndex].tableContext.schemaName = currentSchema
                tabManager.tabs[tabIndex].pagination.reset()
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
                        tabManager.tabs[tabIndex].pagination.reset()
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

        // If current tab has unsaved changes, active filters, or sorting, open in a new native tab
        let hasActiveWork = changeManager.hasChanges
            || selectedTabFilterState.hasAppliedFilters
            || (tabManager.selectedTab?.sortState.isSorting ?? false)
        if hasActiveWork {
            let payload = EditorTabPayload(
                connectionId: connection.id,
                tabType: .table,
                tableName: tableName,
                databaseName: currentDatabase,
                schemaName: currentSchema,
                isView: isView,
                showStructure: showStructure
            )
            WindowManager.shared.openTab(payload: payload)
            return
        }

        // Preview tab mode: reuse or create a preview tab instead of a new native window
        if AppSettingsManager.shared.tabs.enablePreviewTabs {
            openPreviewTab(tableName, isView: isView, databaseName: currentDatabase, schemaName: currentSchema, showStructure: showStructure)
            return
        }

        // Default: open table in a new native tab
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .table,
            tableName: tableName,
            databaseName: currentDatabase,
            schemaName: currentSchema,
            isView: isView,
            showStructure: showStructure
        )
        WindowManager.shared.openTab(payload: payload)
    }

    // MARK: - Preview Tabs

    func openPreviewTab(
        _ tableName: String, isView: Bool = false,
        databaseName: String = "", schemaName: String? = nil,
        showStructure: Bool = false
    ) {
        // Check if a preview window already exists for this connection
        if let preview = WindowLifecycleMonitor.shared.previewWindow(for: connectionId) {
            if let previewCoordinator = Self.coordinator(for: preview.windowId) {
                // Skip if preview tab already shows this table
                if let current = previewCoordinator.tabManager.selectedTab,
                   current.tableContext.tableName == tableName,
                   current.tableContext.databaseName == databaseName {
                    preview.window.makeKeyAndOrderFront(nil)
                    return
                }
                if let oldTab = previewCoordinator.tabManager.selectedTab,
                   let oldTableName = oldTab.tableContext.tableName {
                    previewCoordinator.saveLastFilters(for: oldTableName)
                }
                do {
                    try previewCoordinator.tabManager.replaceTabContent(
                        tableName: tableName,
                        databaseType: connection.type,
                        isView: isView,
                        databaseName: databaseName,
                        schemaName: schemaName,
                        isPreview: true
                    )
                } catch {
                    navigationLogger.error("openPreviewTab replaceTabContent failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                previewCoordinator.clearFilterState()
                if let tabIndex = previewCoordinator.tabManager.selectedTabIndex {
                    let tabId = previewCoordinator.tabManager.tabs[tabIndex].id
                    previewCoordinator.setActiveTableRows(TableRows(), for: tabId)
                    previewCoordinator.tabManager.tabs[tabIndex].display.resultsViewMode = showStructure ? .structure : .data
                    previewCoordinator.tabManager.tabs[tabIndex].pagination.reset()
                    previewCoordinator.toolbarState.isTableTab = true
                }
                preview.window.makeKeyAndOrderFront(nil)
                previewCoordinator.restoreLastHiddenColumnsForTable(tableName)
                previewCoordinator.restoreFiltersForTable(tableName)
                previewCoordinator.runQuery()
                return
            }
        }

        // No preview window exists but current tab can be reused: replace in-place.
        // This covers: preview tabs, non-preview table tabs with no active work,
        // and empty/default query tabs (no user-entered content).
        let isReusableTab: Bool = {
            guard let tab = tabManager.selectedTab else { return false }
            if tab.isPreview { return true }
            // Table tab with no active work
            if tab.tabType == .table && !changeManager.hasChanges
                && !selectedTabFilterState.hasAppliedFilters && !tab.sortState.isSorting {
                return true
            }
            // Empty/default query tab (no user content, no results, never executed)
            if tab.tabType == .query && tab.execution.lastExecutedAt == nil
                && tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return false
        }()
        if let selectedTab = tabManager.selectedTab, isReusableTab {
            // Skip if already showing this table
            if selectedTab.tableContext.tableName == tableName, selectedTab.tableContext.databaseName == databaseName {
                return
            }
            // If preview tab has active work, promote it and open new tab instead
            let hasUnsavedQuery = tabManager.selectedTab.map { tab in
                tab.tabType == .query && !tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? false
            let previewHasWork = changeManager.hasChanges
                || selectedTabFilterState.hasAppliedFilters
                || selectedTab.sortState.isSorting
                || hasUnsavedQuery
            if previewHasWork {
                promotePreviewTab()
                let payload = EditorTabPayload(
                    connectionId: connection.id,
                    tabType: .table,
                    tableName: tableName,
                    databaseName: databaseName,
                    schemaName: schemaName,
                    isView: isView,
                    showStructure: showStructure
                )
                WindowManager.shared.openTab(payload: payload)
                return
            }
            if let oldTableName = selectedTab.tableContext.tableName {
                saveLastFilters(for: oldTableName)
            }
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
                navigationLogger.error("openPreviewTab replaceTabContent failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            clearFilterState()
            if let (tab, tabIndex) = tabManager.selectedTabAndIndex {
                setActiveTableRows(TableRows(), for: tab.id)
                tabManager.tabs[tabIndex].display.resultsViewMode = showStructure ? .structure : .data
                tabManager.tabs[tabIndex].pagination.reset()
                toolbarState.isTableTab = true
            }
            restoreLastHiddenColumnsForTable(tableName)
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
            schemaName: schemaName,
            isView: isView,
            showStructure: showStructure,
            isPreview: true
        )
        WindowManager.shared.openTab(payload: payload)
    }

    func promotePreviewTab() {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              tab.isPreview else { return }
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
        WindowManager.shared.openTab(payload: payload)
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
        clearFilterState()
        let previousDatabase = toolbarState.databaseName
        toolbarState.databaseName = database

        do {
            try await DatabaseManager.shared.switchDatabase(to: database, for: connectionId)

            closeSiblingNativeWindows()
            persistence.saveNowSync(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
            tabSessionRegistry.removeAll()
            tabManager.tabs = []
            tabManager.selectedTabId = nil
            await SchemaService.shared.invalidate(connectionId: connectionId)

            await refreshTables()
        } catch {
            toolbarState.databaseName = previousDatabase

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

        clearFilterState()
        let previousSchema = toolbarState.databaseName
        toolbarState.databaseName = schema

        do {
            try await DatabaseManager.shared.switchSchema(to: schema, for: connectionId)

            closeSiblingNativeWindows()
            persistence.saveNowSync(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
            tabSessionRegistry.removeAll()
            tabManager.tabs = []
            tabManager.selectedTabId = nil
            await SchemaService.shared.invalidate(connectionId: connectionId)

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
