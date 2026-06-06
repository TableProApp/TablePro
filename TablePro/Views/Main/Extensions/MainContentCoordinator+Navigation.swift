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

    func openTableTab(
        _ table: TableInfo,
        showStructure: Bool = false,
        redirectToSibling: Bool = false,
        forceNonPreview: Bool = false,
        activateGridFocus: Bool = false
    ) {
        openTableTab(
            table.name,
            schema: table.schema,
            showStructure: showStructure,
            isView: table.type == .view,
            redirectToSibling: redirectToSibling,
            forceNonPreview: forceNonPreview,
            activateGridFocus: activateGridFocus
        )
    }

    func openTableTab(
        _ tableName: String,
        schema: String? = nil,
        showStructure: Bool = false,
        isView: Bool = false,
        redirectToSibling: Bool = false,
        forceNonPreview: Bool = false,
        activateGridFocus: Bool = false
    ) {
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

        let resolvedSchema = schema
        let createAsPreview = !forceNonPreview && AppSettingsManager.shared.tabs.enablePreviewTabs

        // Fast path: if this table is already the active tab in the same database, skip all work
        if let current = tabManager.selectedTab,
           current.tabType == .table,
           current.tableContext.tableName == tableName,
           current.tableContext.databaseName == currentDatabase,
           current.tableContext.schemaName == resolvedSchema {
            if showStructure, let (_, tabIndex) = tabManager.selectedTabAndIndex {
                tabManager.mutate(at: tabIndex) { $0.display.resultsViewMode = .structure }
            }
            if activateGridFocus {
                focusActiveGrid()
            }
            return
        }

        if activateGridFocus {
            pendingGridFocusOnOpen = true
        }

        // During database switch, update the existing tab in-place instead of
        // opening a new native window tab.
        if case .loading = SchemaService.shared.state(for: connectionId) {
            if tabManager.tabs.isEmpty {
                do {
                    try tabManager.addTableTab(
                        tableName: tableName,
                        databaseType: connection.type,
                        databaseName: currentDatabase,
                        schemaName: resolvedSchema
                    )
                } catch {
                    navigationLogger.error("openTableTab addTableTab failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                pendingGridFocusOnOpen = false
            }
            return
        }

        // Opt-in cross-window navigation: if requested (e.g. quick switcher),
        // and another window already shows this table, focus that window.
        // Default-off so sidebar clicks and other window-local actions stay
        // window-local instead of stealing focus to a sibling.
        if redirectToSibling {
            for sibling in MainContentCoordinator.allActiveCoordinators()
                where sibling !== self && sibling.connectionId == connectionId {
                let hasMatch = sibling.tabManager.tabs.contains { tab in
                    tab.tabType == .table
                        && tab.tableContext.tableName == tableName
                        && tab.tableContext.databaseName == currentDatabase
                        && tab.tableContext.schemaName == resolvedSchema
                }
                guard hasMatch,
                      let windowId = sibling.windowId,
                      let window = WindowLifecycleMonitor.shared.window(for: windowId) else { continue }
                pendingGridFocusOnOpen = false
                window.makeKeyAndOrderFront(nil)
                return
            }
        }

        // If no tabs exist (empty state), add a table tab directly.
        if tabManager.tabs.isEmpty {
            addFirstTableTab(
                tableName: tableName,
                currentDatabase: currentDatabase,
                resolvedSchema: resolvedSchema,
                isView: isView,
                createAsPreview: createAsPreview,
                isInPlace: navigationModel == .inPlace
            )
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
                    schemaName: resolvedSchema
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

        if isActiveTabReusable {
            reuseActiveTab(
                for: tableName,
                currentDatabase: currentDatabase,
                resolvedSchema: resolvedSchema,
                isView: isView,
                showStructure: showStructure,
                createAsPreview: createAsPreview
            )
            return
        }

        promotePreviewTab()
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .table,
            tableName: tableName,
            databaseName: currentDatabase,
            schemaName: resolvedSchema,
            isView: isView,
            showStructure: showStructure,
            isPreview: createAsPreview
        )
        WindowManager.shared.openTab(payload: payload)
    }

    private func addFirstTableTab(
        tableName: String,
        currentDatabase: String,
        resolvedSchema: String?,
        isView: Bool,
        createAsPreview: Bool,
        isInPlace: Bool
    ) {
        do {
            if createAsPreview {
                try tabManager.addPreviewTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase,
                    schemaName: resolvedSchema
                )
            } else {
                try tabManager.addTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase,
                    schemaName: resolvedSchema
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
                tab.tableContext.schemaName = resolvedSchema
                tab.pagination.reset()
            }
            toolbarState.isTableTab = true
        }
        restoreLastHiddenColumnsForTable(tableName)
        restoreFiltersForTable(tableName)
        if isInPlace, let dbIndex = Int(currentDatabase) {
            selectRedisDatabaseAndQuery(dbIndex)
        } else {
            lazyLoadCurrentTabIfNeeded()
        }
    }

    private func reuseActiveTab(
        for tableName: String,
        currentDatabase: String,
        resolvedSchema: String?,
        isView: Bool,
        showStructure: Bool,
        createAsPreview: Bool
    ) {
        if let oldTableName = tabManager.selectedTab?.tableContext.tableName {
            saveLastFilters(for: oldTableName)
        }
        do {
            try tabManager.replaceTabContent(
                tableName: tableName,
                databaseType: connection.type,
                isView: isView,
                databaseName: currentDatabase,
                schemaName: resolvedSchema,
                isPreview: createAsPreview
            )
        } catch {
            navigationLogger.error("openTableTab replaceTabContent failed: \(error.localizedDescription, privacy: .public)")
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
        if let tabId = tabManager.selectedTab?.id {
            cancelTableLoad(for: tabId)
        }
        lazyLoadCurrentTabIfNeeded()
    }

    // MARK: - Preview Tabs

    var isActiveTabReusable: Bool {
        guard let tab = tabManager.selectedTab else { return false }
        if changeManager.hasChanges
            || selectedTabFilterState.hasAppliedFilters
            || tab.hasUserActiveSort {
            return false
        }
        if tab.isPreview { return true }
        if tab.tabType == .query,
           tab.execution.lastExecutedAt == nil,
           tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    func promotePreviewTab() {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              tab.isPreview else { return }
        tabManager.mutate(at: tabIndex) { $0.isPreview = false }
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
        let previousDatabase = toolbarState.currentDatabase
        toolbarState.currentDatabase = database

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

            closeSiblingNativeWindows()
            persistence.saveNowSync(tabs: tabManager.tabs, selectedTabId: tabManager.selectedTabId)
            tabSessionRegistry.removeAll()
            tabManager.tabs = []
            tabManager.selectedTabId = nil
        } catch {
            toolbarState.currentSchema = previousSchema

            navigationLogger.error("Failed to switch schema: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Schema Switch Failed"),
                message: error.localizedDescription,
                window: contentWindow
            )
        }
    }

    /// Drop a database. Called from the database switcher's confirmation dialog.
    func dropDatabase(name: String) async {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            navigationLogger.warning("dropDatabase(name: \(name, privacy: .public)) ignored: no active driver")
            return
        }

        do {
            try await driver.dropDatabase(name: name)
        } catch {
            navigationLogger.error("Failed to drop database: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Drop Failed"),
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
