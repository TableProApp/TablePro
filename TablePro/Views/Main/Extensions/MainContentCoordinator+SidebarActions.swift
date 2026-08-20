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

    func editViewDefinition(_ viewName: String) {
        Task {
            do {
                let definition = try await DatabaseManager.shared.withBrowseMetadataDriver(connectionId: self.connection.id) { driver in
                    try await driver.fetchViewDefinition(view: viewName)
                }

                let payload = EditorTabPayload(
                    connectionId: connection.id,
                    tabType: .query,
                    initialQuery: definition
                )
                WindowManager.shared.openTab(payload: payload)
            } catch {
                let driver = DatabaseManager.shared.driver(for: self.connection.id)
                let template = driver?.editViewFallbackTemplate(viewName: viewName)
                    ?? "CREATE OR REPLACE VIEW \(viewName) AS\nSELECT * FROM table_name;"
                let fallbackSQL = "-- Could not fetch view definition: \(error.localizedDescription)\n\(template)"

                let payload = EditorTabPayload(
                    connectionId: connection.id,
                    tabType: .query,
                    initialQuery: fallbackSQL
                )
                WindowManager.shared.openTab(payload: payload)
            }
        }
    }

    // MARK: - Export/Import

    func openExportDialog(preselectedTableNames: Set<String>? = nil) {
        exportPreselection = preselectedTableNames.map { .tables($0) }
        activeSheet = .exportDialog
    }

    func openExportDialog(containers: [DatabaseContainerRef]) {
        guard !containers.isEmpty else { return }
        exportPreselection = .containers(containers)
        activeSheet = .exportDialog
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

    func supportedMaintenanceOperations() -> [String] {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return [] }
        return driver.supportedMaintenanceOperations() ?? []
    }

    func showMaintenanceSheet(
        operation: String,
        tableName: String,
        database: String? = nil,
        schema: String? = nil
    ) {
        activeSheet = .maintenance(
            operation: operation, tableName: tableName, database: database, schema: schema
        )
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
        operation: String,
        tableName: String,
        options: [String: String],
        database: String? = nil,
        schema: String? = nil
    ) {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
        guard let statements = driver.maintenanceStatements(
            operation: operation, table: tableName, options: options
        ) else { return }
        /// The object the user picked names its own database, and only a command that names none
        /// falls back to where the browser is pointing. `resolvedScope` is what decides that, so a
        /// schema is never carried across a database boundary.
        guard let scope = services.databaseManager.resolvedScope(
            database: database, schema: schema, for: connectionId
        ) ?? browseScope else { return }

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
                    operationDescription: operation
                )
            )
            guard case .authorized = decision else {
                if let reason = decision.deniedReason {
                    await AlertHelper.showErrorSheet(
                        title: String(format: String(localized: "%@ failed"), operation),
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
                    title: String(format: String(localized: "%@ completed"), operation),
                    message: lastResult?.statusMessage
                        ?? String(format: String(localized: "%@ on %@ completed successfully."), operation, tableName),
                    window: self.contentWindow
                )
            } catch {
                await AlertHelper.showErrorSheet(
                    title: String(format: String(localized: "%@ failed"), operation),
                    message: error.localizedDescription,
                    window: self.contentWindow
                )
            }
        }
    }
}
