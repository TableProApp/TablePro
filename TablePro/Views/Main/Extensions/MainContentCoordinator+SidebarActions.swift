//
//  MainContentCoordinator+SidebarActions.swift
//  TablePro
//
//  Sidebar context menu actions for MainContentCoordinator.
//

import AppKit
import Foundation
import TableProPluginKit
import UniformTypeIdentifiers

extension MainContentCoordinator {
    // MARK: - Result Set Operations

    var canPinActiveResultSet: Bool {
        guard let tab = tabManager.selectedTab else { return false }
        return ResultTabBarPolicy.canPin(tabType: tab.tabType, display: tab.display)
    }

    var isActiveResultSetPinned: Bool {
        tabManager.selectedTab?.display.activeResultSet?.isPinned == true
    }

    func togglePinResultSet(id: UUID) {
        guard let tabIdx = tabManager.selectedTabIndex else { return }
        tabManager.mutate(at: tabIdx) { $0.display.togglePin(resultSetId: id) }
    }

    func closeResultSet(id: UUID) {
        guard let tabIdx = tabManager.selectedTabIndex else { return }
        let rs = tabManager.tabs[tabIdx].display.resultSets.first { $0.id == id }
        guard rs?.isPinned != true else { return }
        let tabId = tabManager.tabs[tabIdx].id
        tabManager.mutate(at: tabIdx) { $0.display.resultSets.removeAll { $0.id == id } }
        if tabManager.tabs[tabIdx].display.activeResultSetId == id {
            let newActiveId = tabManager.tabs[tabIdx].display.resultSets.last?.id
            applyResultSetSwitch(to: newActiveId, in: tabId)
        }
        if tabManager.tabs[tabIdx].display.resultSets.isEmpty {
            setActiveTableRows(TableRows(), for: tabId)
            tabManager.mutate(at: tabIdx) { tab in
                tab.execution.errorMessage = nil
                tab.execution.rowsAffected = 0
                tab.execution.executionTime = nil
                tab.execution.statusMessage = nil
                tab.schemaVersion += 1
                tab.display.isResultsCollapsed = true
            }
            toolbarState.isResultsCollapsed = true
        }
    }

    var canClearActiveQueryResults: Bool {
        guard let tab = tabManager.selectedTab, tab.tabType == .query else { return false }
        return !tabSessionRegistry.tableRows(for: tab.id).rows.isEmpty || tab.execution.lastExecutedAt != nil
    }

    func clearActiveQueryResults() {
        guard let tabIdx = tabManager.selectedTabIndex else { return }
        let tabId = tabManager.tabs[tabIdx].id

        if let lastPinned = tabManager.tabs[tabIdx].display.resultSets.last(where: \.isPinned) {
            applyResultSetSwitch(to: lastPinned.id, in: tabId)
            tabManager.mutate(at: tabIdx) { $0.display.removeUnpinnedResults() }
            return
        }

        setActiveTableRows(TableRows(), for: tabId)
        tabManager.mutate(at: tabIdx) { tab in
            tab.display.removeUnpinnedResults()
            tab.execution.errorMessage = nil
            tab.execution.rowsAffected = 0
            tab.execution.executionTime = nil
            tab.execution.statusMessage = nil
            tab.execution.lastExecutedAt = nil
            tab.schemaVersion += 1
            tab.display.isResultsCollapsed = true
        }
        toolbarState.isResultsCollapsed = true
    }

    // MARK: - Table Operations

    func createNewTable() {
        guard !safeModeLevel.blocksAllWrites else { return }

        if tabManager.tabs.isEmpty {
            tabManager.addCreateTableTab(databaseName: browseDatabaseName)
        } else {
            let payload = EditorTabPayload(
                connectionId: connection.id,
                tabType: .createTable,
                databaseName: browseDatabaseName
            )
            WindowManager.shared.openTab(payload: payload)
        }
    }

    // MARK: - View Operations

    func createView() {
        guard !safeModeLevel.blocksAllWrites else { return }

        let driver = DatabaseManager.shared.driver(for: connection.id)
        let template = driver?.createViewTemplate()
            ?? "CREATE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            databaseName: browseDatabaseName,
            initialQuery: template
        )
        WindowManager.shared.openTab(payload: payload)
    }

    /// Opens the engine's CREATE TYPE template in a query tab, the way Create New View does. A type
    /// has no form of its own: its shape is the statement, and the editor is where that is written.
    func createType(database: String?, schema: String?) {
        guard !safeModeLevel.blocksAllWrites else { return }
        guard let driver = DatabaseManager.shared.driver(for: connection.id),
              let template = driver.createTypeTemplate(schema: schema ?? toolbarState.currentSchema)
        else { return }

        let targetDatabase = database.flatMap { $0.isEmpty ? nil : $0 } ?? browseDatabaseName
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            databaseName: targetDatabase,
            schemaName: schema,
            initialQuery: template
        )
        WindowManager.shared.openTab(payload: payload)
    }

    /// Reads the view the row names, in the database and schema the row names, and opens the query
    /// tab there. It used to read through the browse scope with the name alone, so a view selected
    /// in another schema opened the definition of a same-named view in the browsed one, and running
    /// it replaced that other view.
    func editViewDefinition(_ ref: DatabaseTreeTableRef) {
        guard let target = objectTarget(for: ref) else { return }
        let viewName = ref.table.name
        Task {
            let query: String
            do {
                query = try await DatabaseManager.shared.withMetadataDriver(scope: target.scope) { driver in
                    try await driver.fetchViewDefinition(view: viewName)
                }
            } catch {
                query = Self.viewDefinitionFallback(
                    viewName: viewName,
                    error: error,
                    driver: DatabaseManager.shared.driver(for: self.connection.id)
                )
            }
            WindowManager.shared.openTab(payload: EditorTabPayload(
                connectionId: connection.id,
                tabType: .query,
                databaseName: target.scope.database,
                schemaName: target.scope.schema,
                initialQuery: query
            ))
        }
    }

    /// Every line of the error is commented out. A driver error can span several lines, and only the
    /// first used to be, so the rest landed in the query tab as SQL.
    static func viewDefinitionFallback(viewName: String, error: Error, driver: DatabaseDriver?) -> String {
        let template = driver?.editViewFallbackTemplate(viewName: viewName)
            ?? "CREATE OR REPLACE VIEW \(viewName) AS\nSELECT * FROM table_name;"
        let reason = error.localizedDescription
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "-- \($0)" }
            .joined(separator: "\n")
        let heading = "-- " + String(localized: "Could not fetch the view definition:")
        return "\(heading)\n\(reason)\n\(template)"
    }

    // MARK: - Export/Import

    /// The scope travels with the names because a bare name does not identify a table. Without it
    /// the dialog resolved `orders` against whichever container it considered current.
    func openExportDialog(preselectedTableNames: Set<String>? = nil, scope: DatabaseContainerRef? = nil) {
        exportPreselection = preselectedTableNames.map { .tables(names: $0, scope: scope) }
        activeSheet = .exportDialog
    }

    func openExportDialog(containers: [DatabaseContainerRef]) {
        guard !containers.isEmpty else { return }
        exportPreselection = .containers(containers)
        activeSheet = .exportDialog
    }

    /// Copies rows into another open connection. The tables the user right-clicked travel with the
    /// request rather than being read back from the object browser, which may have moved on by the
    /// time the sheet appears.
    func openTableTransferSheet(preselectedTableNames: Set<String> = [], schema: String? = nil) {
        activeSheet = .transferTables(tables: preselectedTableNames, schema: schema)
    }

    func openExportQueryResultsDialog() {
        guard let tab = tabManager.selectedTab,
              !tabSessionRegistry.tableRows(for: tab.id).rows.isEmpty else { return }
        activeSheet = .exportQueryResults
    }

    func openImportDialog(formatId: String) {
        guard !safeModeLevel.blocksAllWrites else { return }
        guard PluginManager.shared.supportsImport(for: connection.type) else {
            AlertHelper.showErrorSheet(
                title: String(localized: "Import Not Supported"),
                message: String(format: String(localized: "Import is not supported for %@ connections."), connection.type.rawValue),
                window: nil
            )
            return
        }
        guard let plugin = PluginManager.shared.importPlugin(forFormat: formatId) else { return }
        let pluginType = type(of: plugin)

        let panel = NSOpenPanel()
        var contentTypes: [UTType] = []
        for ext in pluginType.acceptedFileExtensions {
            if let utType = UTType(filenameExtension: ext) {
                contentTypes.append(utType)
            }
        }
        if !pluginType.requiresTargetTable, let gzType = UTType(filenameExtension: "gz") {
            contentTypes.append(gzType)
        }
        if !contentTypes.isEmpty {
            panel.allowedContentTypes = contentTypes
        }
        panel.allowsMultipleSelection = false
        panel.message = String(format: String(localized: "Select %@ file to import"), pluginType.formatDisplayName)

        guard let window = contentWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importFileURL = url
            switch ImportRouting.route(formatId: formatId, requiresTargetTable: pluginType.requiresTargetTable) {
            case .statement(let id): self?.activeSheet = .importDialog(formatId: id)
            case .rowMapping(let id): self?.activeSheet = .rowImport(formatId: id)
            }
        }
    }

    // MARK: - Maintenance

    func maintenanceOperations() -> [PluginMaintenanceOperation] {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return [] }
        return driver.maintenanceOperations() ?? []
    }

    func showMaintenanceSheet(
        operation: PluginMaintenanceOperation,
        tableName: String,
        database: String? = nil,
        schema: String? = nil
    ) {
        activeSheet = .maintenance(
            operation: operation, tableName: tableName, database: database, schema: schema
        )
    }

    /// The statements the confirmation sheet shows, built by the driver that will run them.
    ///
    /// Synchronous and pure, so the sheet can call it from `body` on every toggle. It used to write
    /// its own SQL instead, which disagreed with what ran: `REINDEX orders`, not valid SQL, where
    /// `REINDEX TABLE "orders"` runs.
    func maintenancePreview(
        operation: PluginMaintenanceOperation,
        tableName: String?,
        schema: String?,
        options: [String: String]
    ) -> [String] {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return [] }
        return driver.maintenanceStatements(
            operation: operation.name,
            table: operation.target(tableName),
            schema: schema,
            options: options
        ) ?? []
    }

    /// Runs against the database the object it names lives in, on a scoped lease.
    ///
    /// A maintenance statement names its table and nothing else, so where it lands is decided
    /// entirely by the connection's current database. Executing on the session driver directly left
    /// that to chance: a cross-database tab pins the shared handle to its own database for the
    /// length of its query and deliberately writes no session state back, so `OPTIMIZE TABLE
    /// role_ability` could optimize the copy in another database while the sheet reported success.
    /// Every other statement the user owns takes a scoped lease; this one now does too, which also
    /// puts it behind the same gate rather than interleaving with a tab's work on one handle.
    func executeMaintenance(
        operation: PluginMaintenanceOperation,
        tableName: String,
        options: [String: String],
        database: String? = nil,
        schema: String? = nil
    ) {
        let statements = maintenancePreview(
            operation: operation, tableName: tableName, schema: schema, options: options
        )
        guard !statements.isEmpty else { return }
        /// The object the user picked names its own database, and only a command that names none
        /// falls back to where the browser is pointing. `resolvedScope` is what decides that, so a
        /// schema is never carried across a database boundary.
        guard let scope = services.databaseManager.resolvedScope(
            database: database, schema: schema, for: connectionId
        ) ?? browseScope else { return }

        /// What the statement acts on, which is the database itself for an operation that names no
        /// object. Reporting the table there claimed work the statement never asked for.
        let subject = operation.target(tableName) ?? scope.database
        Task { [weak self] in
            guard let self else { return }
            let decision = await ExecutionGateProvider.shared.authorize(
                OperationRequest(
                    connectionId: self.connectionId,
                    databaseType: self.connection.type,
                    sql: statements.joined(separator: "\n"),
                    kind: .maintenance,
                    caller: .userInterface,
                    capabilities: .interactiveUser,
                    operationDescription: operation.name
                )
            )
            guard case .authorized = decision else {
                if let reason = decision.deniedReason {
                    await AlertHelper.showErrorSheet(
                        title: String(format: String(localized: "%@ failed"), operation.name),
                        message: reason,
                        window: self.contentWindow
                    )
                }
                return
            }
            do {
                var lastResult: QueryResult?
                let route = DatabaseManager.shared.executionRoute(for: scope)
                for sql in statements {
                    /// `.protectedWrite`: a half-applied OPTIMIZE or REPAIR cannot be undone by
                    /// retrying, so the lease is registered to mark the connection busy and is never
                    /// reachable by Stop.
                    lastResult = try await DatabaseManager.shared.withScopedDriver(
                        scope: scope,
                        route: route,
                        cancellation: .protectedWrite
                    ) { scopedDriver in
                        try await scopedDriver.execute(query: sql)
                    }
                }
                await AlertHelper.showInfoSheet(
                    title: String(format: String(localized: "%@ completed"), operation.name),
                    message: lastResult?.statusMessage
                        ?? String(
                            format: String(localized: "%@ on %@ completed successfully."),
                            operation.name,
                            subject
                        ),
                    window: self.contentWindow
                )
            } catch {
                await AlertHelper.showErrorSheet(
                    title: String(format: String(localized: "%@ failed"), operation.name),
                    message: error.localizedDescription,
                    window: self.contentWindow
                )
            }
        }
    }
}
