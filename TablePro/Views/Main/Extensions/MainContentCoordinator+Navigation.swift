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
            for: connection.type
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
            forceNonPreview: forceNonPreview,
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
        /// Deliberately records no history entry. This retarget also moves the driver's selected
        /// database (`selectRedisDatabaseAndQuery`), which a restore does not do, so a Back would
        /// put the table back while leaving the connection on another database index.
        if navigationModel == .inPlace {
            if let oldTab = tabManager.selectedTab, let oldTableName = oldTab.tableContext.tableName {
                saveLastFilters(for: oldTableName)
            }
            if let tabId = tabManager.selectedTabId {
                let token = TableLoadTracer.shared.begin(
                    tabId: tabId,
                    table: tableName,
                    origin: .inPlace,
                    environment: tableLoadEnvironment
                )
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
                    discardRowsForRetarget()
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
            isPreview: createAsPreview,
            forcesNewTab: forceNewTab
        )
        openTabInNewWindow(payload)
        return .focusedElsewhere
    }

    func activateIfAlreadyOpen(
        tableName: String,
        databaseName: String,
        schemaName: String?,
        showStructure: Bool,
        activateGridFocus: Bool,
        forceNonPreview: Bool = false,
        includeSiblings: Bool
    ) -> WindowTabOpenDisposition? {
        func match(in tabManager: QueryTabManager) -> QueryTab? {
            tabManager.tabShowingTable(
                named: tableName, databaseName: databaseName, schemaName: schemaName
            )
        }

        if let match = match(in: tabManager) {
            if tabManager.selectedTabId != match.id {
                tabManager.selectedTabId = match.id
            }
            /// The gesture that says "keep this one" has to reach a tab that is already open, or
            /// double-clicking a table the sidebar just previewed would leave it disposable.
            if forceNonPreview {
                promotePreviewTab()
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
            guard let match = match(in: sibling.tabManager) else { continue }
            sibling.pendingGridFocusOnOpen = activateGridFocus
            applyStructureMode(showStructure, toTab: match.id, in: sibling.tabManager)
            sibling.selectTabAndFocusWindow(match.id)
            if forceNonPreview {
                sibling.promotePreviewTab()
            }
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
            try tabManager.addTableTab(
                tableName: tableName,
                databaseType: connection.type,
                databaseName: currentDatabase,
                schemaName: resolvedSchema,
                isView: isView,
                isPreview: createAsPreview
            )
        } catch {
            navigationLogger.error("openTableTab tab creation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        if let (tab, tabIndex) = tabManager.selectedTabAndIndex {
            let token = TableLoadTracer.shared.begin(
                tabId: tab.id,
                table: tableName,
                origin: .sidebar,
                environment: tableLoadEnvironment
            )
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
        let departing = captureNavigationEntry()
        if let previousTableName {
            saveLastFilters(for: previousTableName)
        }

        var token: TableLoadTraceToken?
        if let tabId = tabManager.selectedTabId {
            let wasExecuting = tabExecution.isExecuting(tabId)
            let started = TableLoadTracer.shared.begin(
                tabId: tabId,
                table: tableName,
                origin: .sidebar,
                environment: tableLoadEnvironment
            )
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
            if let token { TableLoadTracer.shared.finish(token: token, outcome: .replaceFailed) }
            return false
        }
        if let token { TableLoadTracer.shared.stage(.replaceTabContent, token: token) }
        commitNavigationEntry(departing)
        clearFilterState()
        discardRowsForRetarget(resultsViewMode: showStructure ? .structure : .data)
        restoreLastHiddenColumnsForTable()
        restoreFiltersForTable(tableName)
        if let tabId = tabManager.selectedTab?.id {
            if let token { TableLoadTracer.shared.stage(.cancelPreviousLoad, token: token) }
            cancelTableLoad(for: tabId)
        }
        lazyLoadCurrentTabIfNeeded()
        return true
    }

    /// Drops the outgoing table's rows and says, in the same step, that a load is running.
    ///
    /// The two belong together. A cleared buffer that nothing has called a load is what the status
    /// bar reads as "this tab has no result", and it removes every control that depends on one, so
    /// the bar collapses and then refills as the fetch lands. The execution claim cannot stand in
    /// for the flag: retargeting only schedules the load, so the claim arrives a main-actor turn
    /// later and leaves a renderable frame in between.
    func discardRowsForRetarget(resultsViewMode: ResultsViewMode? = nil) {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex else { return }
        setActiveTableRows(TableRows(), for: tab.id)
        tabManager.mutate(at: tabIndex) { tab in
            if let resultsViewMode {
                tab.display.resultsViewMode = resultsViewMode
            }
            tab.pagination.reset()
            tab.pagination.isLoading = true
        }
        toolbarState.isTableTab = true
    }

    // MARK: - Preview Tabs

    /// Content the user authored that lives nowhere else, so replacing the tab in place would
    /// destroy it. Any navigation that reuses the selected tab must consult this first.
    var selectedTabHoldsProtectedContent: Bool {
        guard let tab = tabManager.selectedTab else { return false }
        if changeManager.hasChanges { return true }
        if tab.holdsQueryWork { return true }
        if hasStagedStructureEdits(in: tab) { return true }
        /// The draft is consulted alongside the toolbar flag because the two answer different
        /// questions: the flag says the draft is complete enough to run, `hasTableDraftWork` says
        /// the user has typed something. A retarget now deletes the draft, so a half-written table
        /// would go with it. `hasUnsavedWork` has always asked the second question.
        if tab.tabType == .createTable {
            return toolbarState.hasCreateTablePending || hasTableDraftWork(in: tab)
        }
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
        openTabInNewWindow(payload)
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
            /// A user who dismissed the password prompt already knows why nothing happened, and
            /// telling them their own decision failed is noise, not news.
            guard !DatabaseCancellationDiagnosis.isCancellation(error) else { return false }
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

    /// Applies both dimensions a caller named, in the order this engine can take them.
    ///
    /// The one entry point for anything that names a database and a schema together: a link, a
    /// sidebar row, a restored tab. Naming two dimensions and picking one is what sent a database
    /// name to `switchSchema` on every engine that has schemas, and what asked a schema-only
    /// engine to switch a database it does not have, which surfaced the driver's own
    /// "does not support database switching" as an alert on every table click (#2262).
    /// `switchContainer` cannot express this because it carries one container.
    ///
    /// A step already satisfied is skipped, and that is decided when the step runs rather than
    /// from a snapshot taken up front, because an earlier step moves what the next one compares
    /// against: on an engine that groups by schema, switching database resets the session to the
    /// engine's default schema. Reading both values before either switch drops the schema step as
    /// redundant and then leaves the session on `dbo`.
    ///
    /// Each value comes from the live session, never from `toolbarState`: a database switch moves
    /// the session schema without touching the toolbar, so comparing against the toolbar skips
    /// the switch exactly when the session needs it.
    func switchContainers(database: String?, schema: String?) async {
        let steps = ContainerSwitchPlanner.plan(
            database: database,
            schema: schema,
            switchable: PluginManager.shared.switchableContainers(for: connection.type)
        )

        for step in steps {
            let session = services.databaseManager.session(for: connectionId)
            switch step {
            case .database(let name):
                guard name != session?.resolvedBrowseDatabase else { continue }
                /// A schema belongs to a database, so a failed database switch stops the plan
                /// rather than applying the schema against whatever is still open.
                guard await switchDatabase(to: name) else { return }
            case .schema(let name):
                guard name != session?.browseSchema else { continue }
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
        for database in Set(request.targets.filter { $0.kind == .schema }.compactMap(\.database)) {
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
                if let tabId = tabManager.selectedTab?.id {
                    declineTableLoad(for: tabId)
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
