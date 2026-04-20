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

    func closeResultSet(id: UUID) {
        guard let tabIdx = tabManager.selectedTabIndex else { return }
        let rs = tabManager.tabs[tabIdx].resultSets.first { $0.id == id }
        guard rs?.isPinned != true else { return }
        tabManager.tabs[tabIdx].resultSets.removeAll { $0.id == id }
        if tabManager.tabs[tabIdx].activeResultSetId == id {
            tabManager.tabs[tabIdx].activeResultSetId = tabManager.tabs[tabIdx].resultSets.last?.id
        }
        if tabManager.tabs[tabIdx].resultSets.isEmpty {
            tabManager.tabs[tabIdx].rowBuffer = RowBuffer()
            tabManager.tabs[tabIdx].resultColumns = []
            tabManager.tabs[tabIdx].columnTypes = []
            tabManager.tabs[tabIdx].resultRows = []
            tabManager.tabs[tabIdx].errorMessage = nil
            tabManager.tabs[tabIdx].rowsAffected = 0
            tabManager.tabs[tabIdx].executionTime = nil
            tabManager.tabs[tabIdx].statusMessage = nil
            tabManager.tabs[tabIdx].resultVersion += 1
            tabManager.tabs[tabIdx].isResultsCollapsed = true
            toolbarState.isResultsCollapsed = true
        }
    }

    // MARK: - Table Operations

    func createNewTable() {
        guard !safeModeLevel.blocksAllWrites else { return }

        if tabManager.tabs.isEmpty {
            tabManager.addCreateTableTab(databaseName: connection.database)
        } else {
            let payload = EditorTabPayload(
                connectionId: connection.id,
                tabType: .createTable,
                databaseName: connection.database
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
            databaseName: connection.database,
            initialQuery: template
        )
        WindowManager.shared.openTab(payload: payload)
    }

    func editViewDefinition(_ viewName: String) {
        Task { @MainActor in
            do {
                guard let driver = DatabaseManager.shared.driver(for: self.connection.id) else { return }
                let definition = try await driver.fetchViewDefinition(view: viewName)

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
        exportPreselectedTableNames = preselectedTableNames
        activeSheet = .exportDialog
    }

    func openExportQueryResultsDialog() {
        guard let tab = tabManager.selectedTab, !tab.rowBuffer.rows.isEmpty else { return }
        activeSheet = .exportQueryResults
    }

    func openImportDialog() {
        guard !safeModeLevel.blocksAllWrites else { return }
        guard PluginManager.shared.supportsImport(for: connection.type) else {
            AlertHelper.showErrorSheet(
                title: String(localized: "Import Not Supported"),
                message: String(format: String(localized: "SQL import is not supported for %@ connections."), connection.type.rawValue),
                window: nil
            )
            return
        }
        let panel = NSOpenPanel()
        var contentTypes: [UTType] = []
        for (_, plugin) in PluginManager.shared.importPlugins {
            for ext in type(of: plugin).acceptedFileExtensions {
                if let utType = UTType(filenameExtension: ext) {
                    contentTypes.append(utType)
                }
            }
        }
        if let gzType = UTType(filenameExtension: "gz") {
            contentTypes.append(gzType)
        }
        if !contentTypes.isEmpty {
            panel.allowedContentTypes = contentTypes
        }
        panel.allowsMultipleSelection = false
        panel.message = "Select SQL file to import"

        guard let window = contentWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importFileURL = url
            self?.activeSheet = .importDialog
        }
    }

    // MARK: - Maintenance

    func supportedMaintenanceOperations() -> [String] {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return [] }
        return driver.supportedMaintenanceOperations() ?? []
    }

    func showMaintenanceSheet(operation: String, tableName: String) {
        activeSheet = .maintenance(operation: operation, tableName: tableName)
    }

    func executeMaintenance(operation: String, tableName: String, options: [String: String]) {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
        guard let statements = driver.maintenanceStatements(
            operation: operation, table: tableName, options: options
        ) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var lastResult: QueryResult?
                for sql in statements {
                    lastResult = try await driver.execute(query: sql)
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
