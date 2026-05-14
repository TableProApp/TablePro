import AppKit
import Foundation

extension MainContentCoordinator {
    /// Open (or focus) an ER Diagram tab for the current database/schema.
    /// If a tab with the same schema key is already open, select it; otherwise
    /// add a new ER Diagram tab.
    func showERDiagram() {
        let dbName = activeDatabaseName
        let schemaName = DatabaseManager.shared.session(for: connectionId)?.currentSchema
        let schemaKey = "\(dbName).\(schemaName ?? "default")"

        if let existing = tabManager.tabs.first(where: {
            $0.tabType == .erDiagram && $0.display.erDiagramSchemaKey == schemaKey
        }) {
            tabManager.selectTab(id: existing.id)
            return
        }

        tabManager.addERDiagramTab(schemaKey: schemaKey, databaseName: dbName)
    }
}
