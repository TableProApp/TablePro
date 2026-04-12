//
//  MainContentCoordinator+SidebarActions.swift
//  TablePro
//
//  Sidebar context menu actions for MainContentCoordinator.
//

import AppKit
import Foundation
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
            WindowOpener.shared.openNativeTab(payload)
        }
    }

    func showERDiagram() {
        openERDiagramTab()
    }

    // MARK: - Routine Tab Operations

    func openRoutineTab(_ routineName: String, routineType: RoutineInfo.RoutineType) {
        if tabManager.tabs.isEmpty {
            tabManager.addTab(databaseName: connection.database)
            if let idx = tabManager.selectedTabIndex {
                tabManager.tabs[idx].tableName = routineName
                tabManager.tabs[idx].isRoutine = true
                tabManager.tabs[idx].routineType = routineType
                tabManager.tabs[idx].showStructure = true
            }
        } else {
            let payload = EditorTabPayload(
                connectionId: connection.id,
                tabType: .table,
                tableName: routineName,
                databaseName: connection.database,
                isRoutine: true,
                routineType: routineType,
                showStructure: true
            )
            WindowOpener.shared.openNativeTab(payload)
        }
    }

    func openQueryInTab(_ query: String) {
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            databaseName: connection.database,
            initialQuery: query
        )
        WindowOpener.shared.openNativeTab(payload)
    }

    func createProcedure() {
        guard !safeModeLevel.blocksAllWrites else { return }
        let driver = DatabaseManager.shared.driver(for: connection.id)
        let template = driver?.createProcedureTemplate()
            ?? "CREATE PROCEDURE procedure_name()\nBEGIN\n    -- procedure body\nEND;"
        openQueryInTab(template)
    }

    func createFunction() {
        guard !safeModeLevel.blocksAllWrites else { return }
        let driver = DatabaseManager.shared.driver(for: connection.id)
        let template = driver?.createFunctionTemplate()
            ?? "CREATE FUNCTION function_name()\nRETURNS INT\nBEGIN\n    RETURN 0;\nEND;"
        openQueryInTab(template)
    }

    func dropRoutine(_ routineName: String, type: RoutineInfo.RoutineType) {
        guard !safeModeLevel.blocksAllWrites else { return }
        let keyword = type == .function ? "FUNCTION" : "PROCEDURE"
        let typeLabel = type == .function
            ? String(localized: "function") : String(localized: "procedure")

        Task { @MainActor in
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(format: String(localized: "Drop %@ '%@'?"), typeLabel, routineName),
                message: String(format: String(localized: "This will permanently delete the %@. This action cannot be undone."), typeLabel),
                confirmButton: String(localized: "Drop"),
                window: contentWindow
            )
            guard confirmed else { return }

            guard let adapter = DatabaseManager.shared.driver(for: connectionId) as? PluginDriverAdapter else { return }
            let sql = adapter.dropObjectStatement(name: routineName, objectType: keyword, schema: nil, cascade: false)

            do {
                _ = try await adapter.execute(query: sql)
                await refreshTables()
            } catch {
                await AlertHelper.showErrorSheet(
                    title: String(format: String(localized: "Drop %@ failed"), typeLabel),
                    message: error.localizedDescription,
                    window: contentWindow
                )
            }
        }
    }

    func showExecuteRoutineSheet(_ routineName: String, type: RoutineInfo.RoutineType) {
        Task { @MainActor in
            guard let driver = DatabaseManager.shared.driver(for: self.connection.id) else { return }
            do {
                let params = try await driver.fetchRoutineParameters(routine: routineName, type: type)
                activeSheet = .executeRoutine(name: routineName, type: type, parameters: params)
            } catch {
                activeSheet = .executeRoutine(name: routineName, type: type, parameters: [])
            }
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
        WindowOpener.shared.openNativeTab(payload)
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
                WindowOpener.shared.openNativeTab(payload)
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
                WindowOpener.shared.openNativeTab(payload)
            }
        }
    }

    // MARK: - Export/Import

    func openExportDialog() {
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
        if let sqlType = UTType(filenameExtension: "sql") {
            contentTypes.append(sqlType)
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
