import AppKit
import Foundation

extension MainContentCoordinator {
    /// Open (or focus) the Query Insights tab for this connection.
    ///
    /// Singleton per connection, resolved the same way the Server Dashboard is:
    /// 1. If any window for this connection already hosts an insights tab, focus that window.
    /// 2. If this window's tabManager is empty, add the tab locally.
    /// 3. Otherwise open a new native window tab so the current tab's content is preserved.
    func showQueryInsights() {
        if let existing = Self.coordinator(forConnection: connectionId, tabMatching: {
            $0.tabType == .insights
        }) {
            existing.contentWindow?.makeKeyAndOrderFront(nil)
            return
        }

        if tabManager.tabs.isEmpty {
            tabManager.addQueryInsightsTab()
            return
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .insights,
            databaseName: browseDatabaseName
        )
        WindowManager.shared.openTab(payload: payload)
    }
}
