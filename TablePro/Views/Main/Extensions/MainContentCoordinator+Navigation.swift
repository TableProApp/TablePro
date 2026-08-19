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

internal enum WindowTabOpenDisposition: Equatable {
    case currentCoordinator
    case focusedElsewhere
}

extension MainContentCoordinator {
    // MARK: - Table Tab Opening

    @discardableResult
    func openTableTab(
        _ table: TableInfo,
        schema: String? = nil,
        showStructure: Bool = false,
        forceNonPreview: Bool = false,
        activateGridFocus: Bool = false,
        forceNewTab: Bool = false
    ) -> WindowTabOpenDisposition? {
        openTableTab(
            table.name,
            schema: schema ?? table.schema,
            showStructure: showStructure,
            isView: !table.type.allowsRowEditing,
            forceNonPreview: forceNonPreview,
            activateGridFocus: activateGridFocus,
            forceNewTab: forceNewTab
        )
    }

    @discardableResult
    func openTableTab(
        _ tableName: String,
        schema: String? = nil,
        showStructure: Bool = false,
        isView: Bool = false,
        forceNonPreview: Bool = false,
        activateGridFocus: Bool = false,
        forceNewTab: Bool = false
    ) -> WindowTabOpenDisposition? {
        let navigationModel = PluginMetadataRegistry.shared.snapshot(
            forTypeId: connection.type.pluginTypeId
        )?.navigationModel ?? .standard

        let currentDatabase: String
        if navigationModel == .inPlace {
            guard tableName.hasPrefix("db"), Int(String(tableName.dropFirst(2))) != nil else {
                return nil
            }
            currentDatabase = String(tableName.dropFirst(2))
        } else {
            currentDatabase = browseDatabaseName
        }

        let resolvedSchema = DatabaseManager.shared.resolvedSchemaName(schema, for: connectionId)
        let createAsPreview = !forceNonPreview && !forceNewTab
            && AppSettingsManager.shared.tabs.enablePreviewTabs

        if !forceNewTab, let disposition = activateIfAlreadyOpen(
            tableName: tableName,
            databaseName: currentDatabase,
            schemaName: resolvedSchema,
            showStructure: showStructure,
            activateGridFocus: activateGridFocus,
            includeSiblings: navigationModel != .inPlace
        ) {
            navigationLogger.debug(
                "[tableload] activateExistingTab table=\(tableName, privacy: .public)"
            )
            return disposition
        }

        /// Not a bare flag. `pendingGridFocusOnOpen` is consumed only when the grid view moves into
        /// a window, which happens for the first table tab and never again, because every later tab
        /// reuses that same view. Setting it directly left the request pending forever and focus in
        /// the sidebar from the second table on.
        if activateGridFocus {
            requestGridFocus()
        }

        // During database switch, update the existing tab in-place instead of
        // opening a new native window tab.
        if case .loading = SchemaService.shared.state(for: connectionId) {
            navigationLogger.debug(
                "[tableload] deferredToSchemaLoad table=\(tableName, privacy: .public) hasTabs=\(!self.tabManager.tabs.isEmpty)"
            )
            if tabManager.tabs.isEmpty {
                do {
                    try tabManager.addTableTab(
                        tableName: tableName,
                        databaseType: connection.type,
                        databaseName: currentDatabase,
                        schemaName: resolvedSchema,
                        isView: isView
                    )
                    return .currentCoordinator
                } catch {
                    navigationLogger.error("openTableTab addTableTab failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                pendingGridFocusOnOpen = false
            }
            return nil
        }

        if tabManager.tabs.isEmpty {
            let didOpen = addFirstTableTab(
                tableName: tableName,
                currentDatabase: currentDatabase,
                resolvedSchema: resolvedSchema,
                isView: isView,
                createAsPreview: createAsPreview,
                isInPlace: navigationModel == .inPlace
            )
            return didOpen ? .currentCoordinator : nil
        }

        // In-place navigation: replace current tab content rather than
        // opening new native window tabs (e.g. Redis database switching).
        if navigationModel == .inPlace {
            if let oldTab = tabManager.selectedTab, let oldTableName = oldTab.tableContext.tableName {
                saveLastFilters(for: oldTableName)
            }
            if let tabId = tabManager.selectedTabId {
                let token = TableLoadTracer.shared.begin(tabId: tabId, table: tableName, origin: .inPlace)
                TableLoadTracer.shared.stage(.openTableTab, token: token, detail: "path=inPlace")
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
                    restoreLastHiddenColumnsForTable()
                    restoreFiltersForTable(tableName)
                    if let dbIndex = Int(currentDatabase) {
                        selectRedisDatabaseAndQuery(dbIndex)
                    }
                }
                return replaced ? .currentCoordinator : nil
            } catch {
                navigationLogger.error("openTableTab replaceTabContent failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        if isActiveTabReusable, !forceNewTab {
            let didOpen = reuseActiveTab(
                for: tableName,
                currentDatabase: currentDatabase,
                resolvedSchema: resolvedSchema,
                isView: isView,
                showStructure: showStructure,
                createAsPreview: createAsPreview
            )
            return didOpen ? .currentCoordinator : nil
        }

        promotePreviewTab()
        navigationLogger.debug(
            "[tableload] handoffToNewWindowTab table=\(tableName, privacy: .public)"
        )
        TableLoadTracer.shared.noteWindowTabHandoff(connectionId: connection.id, table: tableName)
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
        return .focusedElsewhere
    }

    func activateIfAlreadyOpen(
        tableName: String,
        databaseName: String,
        schemaName: String?,
        showStructure: Bool,
        activateGridFocus: Bool,
        includeSiblings: Bool
    ) -> WindowTabOpenDisposition? {
        func matches(_ tab: QueryTab) -> Bool {
            tab.tabType == .table
                && tab.tableContext.tableName == tableName
                && tab.tableContext.databaseName == databaseName
                && tab.tableContext.schemaName == schemaName
        }

        if let match = tabManager.tabs.first(where: matches) {
            if tabManager.selectedTabId != match.id {
                tabManager.selectedTabId = match.id
            }
            applyStructureMode(showStructure, toTab: match.id, in: tabManager)
            if activateGridFocus {
                requestGridFocus()
            }
            return .currentCoordinator
        }

        guard includeSiblings else { return nil }

        for sibling in MainContentCoordinator.allActiveCoordinators()
            where sibling !== self && sibling.connectionId == connectionId {
            guard let match = sibling.tabManager.tabs.first(where: matches) else { continue }
            sibling.pendingGridFocusOnOpen = activateGridFocus
            applyStructureMode(showStructure, toTab: match.id, in: sibling.tabManager)
            sibling.selectTabAndFocusWindow(match.id)
            return .focusedElsewhere
        }
        return nil
    }

    private func applyStructureMode(_ showStructure: Bool, toTab tabId: UUID, in tabManager: QueryTabManager) {
        guard showStructure, let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabManager.mutate(at: index) { $0.display.resultsViewMode = .structure }
    }

    private func addFirstTableTab(
        tableName: String,
        currentDatabase: String,
        resolvedSchema: String?,
        isView: Bool,
        createAsPreview: Bool,
        isInPlace: Bool
    ) -> Bool {
        do {
            if createAsPreview {
                try tabManager.addPreviewTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase,
                    schemaName: resolvedSchema,
                    isView: isView
                )
            } else {
                try tabManager.addTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: currentDatabase,
                    schemaName: resolvedSchema,
                    isView: isView
                )
            }
        } catch {
            navigationLogger.error("openTableTab tab creation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        if let (tab, tabIndex) = tabManager.selectedTabAndIndex {
            let token = TableLoadTracer.shared.begin(tabId: tab.id, table: tableName, origin: .sidebar)
            TableLoadTracer.shared.stage(.openTableTab, token: token, detail: "path=addFirstTab")
            TableLoadTracer.shared.stage(.addFirstTab, token: token)
            tabManager.mutate(at: tabIndex) { tab in
                tab.tableContext.isView = isView
                tab.tableContext.isEditable = !isView
                tab.tableContext.schemaName = resolvedSchema
                tab.pagination.reset()
            }
            toolbarState.isTableTab = true
        }
        restoreLastHiddenColumnsForTable()
        restoreFiltersForTable(tableName)
        if isInPlace, let dbIndex = Int(currentDatabase) {
            selectRedisDatabaseAndQuery(dbIndex)
        } else {
            lazyLoadCurrentTabIfNeeded()
        }
        return true
    }

    private func reuseActiveTab(
        for tableName: String,
        currentDatabase: String,
        resolvedSchema: String?,
        isView: Bool,
        showStructure: Bool,
        createAsPreview: Bool
    ) -> Bool {
        let previousTableName = tabManager.selectedTab?.tableContext.tableName
        if let previousTableName {
            saveLastFilters(for: previousTableName)
        }

        var token: TableLoadTraceToken?
        if let tabId = tabManager.selectedTabId {
            let wasExecuting = tabExecution.isExecuting(tabId)
            let started = TableLoadTracer.shared.begin(tabId: tabId, table: tableName, origin: .sidebar)
            token = started
            TableLoadTracer.shared.stage(
                .openTableTab,
                token: started,
                detail: """
                    path=reuseActiveTab from=\(previousTableName ?? "none") \
                    wasExecuting=\(wasExecuting) hasInFlightQuery=\(currentQueryTask != nil)
                    """
            )
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
            if let token { TableLoadTracer.shared.finish(token: token, outcome: "replaceFailed") }
            return false
        }
        if let token { TableLoadTracer.shared.stage(.replaceTabContent, token: token) }
        clearFilterState()
        if let (tab, tabIndex) = tabManager.selectedTabAndIndex {
            setActiveTableRows(TableRows(), for: tab.id)
            tabManager.mutate(at: tabIndex) {
                $0.display.resultsViewMode = showStructure ? .structure : .data
                $0.pagination.reset()
            }
            toolbarState.isTableTab = true
        }
        restoreLastHiddenColumnsForTable()
        restoreFiltersForTable(tableName)
        if let tabId = tabManager.selectedTab?.id {
            if let token { TableLoadTracer.shared.stage(.cancelPreviousLoad, token: token) }
            cancelTableLoad(for: tabId)
        }
        lazyLoadCurrentTabIfNeeded()
        return true
    }

    // MARK: - Preview Tabs

    /// Content the user authored that lives nowhere else, so replacing the tab in place would
    /// destroy it. Any navigation that reuses the selected tab must consult this first.
    var selectedTabHoldsProtectedContent: Bool {
        guard let tab = tabManager.selectedTab else { return false }
        if changeManager.hasChanges { return true }
        if tab.holdsQueryWork { return true }
        if tab.tabType == .createTable { return toolbarState.hasCreateTablePending }
        return false
    }

    var isActiveTabReusable: Bool {
        guard let tab = tabManager.selectedTab else { return false }
        if selectedTabHoldsProtectedContent { return false }
        if selectedTabFilterState.hasAppliedFilters
            || tab.hasUserActiveSort
            || tab.display.hasPinnedResults {
            return false
        }
        if tab.tabType == .createTable { return true }
        if tab.isPreview { return true }
        if tab.tabType == .query { return true }
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

    private func allTablesMetadataSQL() -> String? {
        let editorLang = PluginManager.shared.editorLanguage(for: connection.type)
        // Non-SQL databases: open a command tab instead
        if editorLang == .javascript {
            tabManager.addTab(
                initialQuery: "db.runCommand({\"listCollections\": 1, \"nameOnly\": false})",
                databaseName: browseDatabaseName
            )
            runQuery()
            return nil
        } else if editorLang == .bash {
            tabManager.addTab(
                initialQuery: "SCAN 0 MATCH * COUNT 100",
                databaseName: browseDatabaseName
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

    /// Moves the browse cursor: what the sidebar lists and which database a new tab
    /// opens in. It never retargets an open tab, and an open tab never calls it.
    /// `persist` records the database as the connection's saved default.
    @discardableResult
    func switchDatabase(to database: String, persist: Bool = true) async -> Bool {
        do {
            try await DatabaseManager.shared.switchDatabase(to: database, for: connectionId, persist: persist)
            toolbarState.currentDatabase = database
            toolbarState.currentSchema = DatabaseManager.shared.session(for: connectionId)?.browseSchema

            await SchemaService.shared.prepareForReload(connectionId: connectionId)

            await refreshTables(currentDatabaseOnly: true)
            syncSidebarObjectSelection()
            return true
        } catch {
            navigationLogger.error("Failed to switch database: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(
                    format: String(localized: "%@ Switch Failed"),
                    PluginManager.shared.containerEntityName(for: connection.type)
                ),
                message: error.localizedDescription,
                window: contentWindow
            )
            return false
        }
    }

    /// Switch the active container (database, or schema for schema-switching-only
    /// engines like BigQuery), routing by the plugin's container switch target.
    /// `target` names the dimension the caller opened, because an engine can switch both and the
    /// engine's primary target cannot tell the two presentations apart.
    func switchContainer(to container: String, target: ContainerSwitchTarget? = nil) async {
        switch target ?? PluginManager.shared.containerSwitchTarget(for: connection.type) {
        case .schema:
            await switchSchema(to: container)
        case .database, nil:
            await switchDatabase(to: container)
        }
    }

    /// Records which container the tab on screen belongs to, so the connections strip can come
    /// back to it.
    ///
    /// Called on every tab change and again when the window becomes key. A window restoring its
    /// tabs picks the selected one before anything is watching the selection, so without the second
    /// call the first thing ever recorded would be whatever the user switched to next, and coming
    /// back to that database would land on the wrong tab.
    func recordSelectedTabContainer() {
        guard let tab = tabManager.selectedTab else { return }
        containerTabHistory.record(
            tabId: tab.id,
            container: WorkspaceAnchoring.containerName(
                of: tab,
                target: PluginManager.shared.containerSwitchTarget(for: connection.type)
            )
        )
    }

    /// Land on the work a container already holds.
    ///
    /// The connections strip returns to the tab you last used when it moves between two
    /// connections. A row for a second database of one connection is the same promise, and without
    /// it the strip moved the object tree while leaving a tab from another database on screen: the
    /// row said one database, the window title said another (#2217).
    ///
    /// A container holding no tab selects nothing. That row is the browse cursor alone, and the
    /// next thing opened lands there anyway.
    func selectTab(inContainer container: String) {
        guard let tabId = containerTabHistory.tabToSelect(
            inContainer: container,
            among: tabManager.tabs,
            target: PluginManager.shared.containerSwitchTarget(for: connection.type)
        ) else { return }
        tabManager.selectedTabId = tabId
    }

    /// Applies both dimensions a link named, in the order this engine can take them.
    ///
    /// A link names dimensions, not one container, so choosing between them is what sent a
    /// database name to `switchSchema` on every engine that has schemas. `switchContainer` cannot
    /// express this because it carries one container; the planner decides which to apply and in
    /// what order, and this runs them.
    func applyLinkedContainers(database: String?, schema: String?) async {
        let steps = ContainerSwitchPlanner.plan(
            database: database,
            schema: schema,
            switchable: PluginManager.shared.switchableContainers(for: connection.type)
        )

        for step in steps {
            switch step {
            case .database(let name):
                guard name != services.databaseManager.session(for: connectionId)?.resolvedBrowseDatabase else {
                    continue
                }
                /// A schema belongs to a database, so a failed database switch stops the plan
                /// rather than applying the schema against whatever is still open.
                guard await switchDatabase(to: name) else { return }
            case .schema(let name):
                await switchSchema(to: name)
            }
        }
    }

    private var schemaEntityName: String {
        guard PluginManager.shared.containerSwitchTarget(for: connection.type) == .schema else {
            return String(localized: "Schema")
        }
        return PluginManager.shared.containerEntityName(for: connection.type)
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

        let previousSchema = toolbarState.currentSchema
        toolbarState.currentSchema = schema

        do {
            try await DatabaseManager.shared.switchSchema(to: schema, for: connectionId)
            syncSidebarObjectSelection()
        } catch {
            toolbarState.currentSchema = previousSchema

            navigationLogger.error("Failed to switch schema: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(format: String(localized: "%@ Switch Failed"), schemaEntityName),
                message: error.localizedDescription,
                window: contentWindow
            )
        }
    }

    func requestContainerDrop(_ targets: [DatabaseContainerRef]) {
        guard !targets.isEmpty else { return }
        let isSchema = targets.contains { $0.kind == .schema }
        containerDropRequest = DatabaseDropRequest(
            targets: targets,
            entityName: isSchema
                ? PluginManager.shared.schemaEntityName(for: connection.type)
                : PluginManager.shared.containerEntityName(for: connection.type),
            entityNamePlural: isSchema
                ? PluginManager.shared.schemaEntityNamePlural(for: connection.type)
                : PluginManager.shared.containerEntityNamePlural(for: connection.type),
            dropsDependentObjects: isSchema
        )
    }

    /// Drop every container in the request, reporting the ones that failed.
    /// A failure on one target never stops the rest: the user asked for all of them.
    func dropContainers(_ request: DatabaseDropRequest) async {
        var failures: [(name: String, message: String)] = []

        for target in request.targets {
            do {
                try await dropContainer(target)
            } catch {
                navigationLogger.error(
                    "Failed to drop \(target.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                failures.append((target.name, error.localizedDescription))
            }
        }

        await DatabaseTreeMetadataService.shared.refreshDatabases(
            connectionId: connectionId,
            databaseType: connection.type
        )
        for database in Set(request.targets.filter { $0.kind == .schema }.map(\.database)) {
            await DatabaseTreeMetadataService.shared.refreshSchemas(
                connectionId: connectionId,
                database: database
            )
        }

        guard !failures.isEmpty else { return }
        AlertHelper.showErrorSheet(
            title: String(localized: "Drop Failed"),
            message: dropFailureMessage(failures),
            window: contentWindow
        )
    }

    private func dropContainer(_ target: DatabaseContainerRef) async throws {
        switch target.kind {
        case .database:
            guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
                throw DatabaseError.notConnected
            }
            try await driver.dropDatabase(name: target.name)
        case .schema:
            guard let scope = DatabaseManager.shared.resolvedScope(
                database: target.database, schema: nil, for: connectionId
            ) else {
                throw DatabaseError.notConnected
            }
            let name = target.name
            try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                try await driver.dropSchema(name: name)
            }
        }
    }

    private func dropFailureMessage(_ failures: [(name: String, message: String)]) -> String {
        failures
            .map { String(format: String(localized: "%1$@: %2$@"), $0.name, $0.message) }
            .joined(separator: "\n")
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
                session.browseDatabase = database
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
        applyBrowseSearch(BrowseSearchState(pattern: "\(prefix)*"))
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
