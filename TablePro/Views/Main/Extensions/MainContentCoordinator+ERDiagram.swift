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
        let dbName = browseDatabaseName
        let schemaName = DatabaseManager.shared.session(for: connectionId)?.browseSchema
        let schemaKey = "\(dbName).\(schemaName ?? "default")"

        if let existing = Self.coordinator(forConnection: connectionId, tabMatching: {
            $0.tabType == .erDiagram && $0.display.erDiagramSchemaKey == schemaKey
        }), let match = existing.tabManager.tabs.first(where: {
            $0.tabType == .erDiagram && $0.display.erDiagramSchemaKey == schemaKey
        }) {
            /// Selecting it, not just raising its window. An editor tab used to be a window, so
            /// raising the window was the whole of showing the tab; now a window holds every tab
            /// and the command did nothing whenever the tab it names is not the one in front.
            existing.selectTabAndFocusWindow(match.id)
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
