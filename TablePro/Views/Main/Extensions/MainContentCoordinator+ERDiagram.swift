import AppKit
import Foundation

extension MainContentCoordinator {
    /// Open (or focus) an ER Diagram tab for the current database/schema.
    ///
    /// Resolution order:
    /// 1. If another window for this connection already hosts an ER Diagram
    ///    tab with the same schema key, focus that window.
    /// 2. If this window's tabManager is empty (fresh window with no restored
    ///    tabs yet), add the ER Diagram tab locally.
    /// 3. Otherwise open a new native window tab so the current tab's content
    ///    (unsaved queries, filters, etc.) is preserved.
    func showERDiagram() {
        let session = DatabaseManager.shared.session(for: connectionId)
        let dbName = session?.activeDatabase ?? connection.database
        let schemaName = session?.currentSchema
        let schemaKey = "\(dbName).\(schemaName ?? "default")"

        if let existing = Self.coordinator(forConnection: connectionId, tabMatching: {
            $0.tabType == .erDiagram && $0.erDiagramSchemaKey == schemaKey
        }) {
            existing.contentWindow?.makeKeyAndOrderFront(nil)
            return
        }

        if tabManager.tabs.isEmpty {
            tabManager.addERDiagramTab(schemaKey: schemaKey, databaseName: dbName)
            return
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .erDiagram,
            databaseName: dbName,
            schemaName: schemaName,
            erDiagramSchemaKey: schemaKey
        )
        WindowManager.shared.openTab(payload: payload)
    }
}
