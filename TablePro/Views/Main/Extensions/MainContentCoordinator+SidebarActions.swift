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

    func openImportDialog() {
        guard !safeModeLevel.blocksAllWrites else { return }
        guard PluginManager.shared.supportsImport(for: connection.type) else {
            AlertHelper.showErrorSheet(
                title: String(localized: "Import Not Supported"),
                message: String(localized: "SQL import is not supported for \(connection.type.rawValue) connections."),
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

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importFileURL = url
            self?.activeSheet = .importDialog
        }
    }
}
