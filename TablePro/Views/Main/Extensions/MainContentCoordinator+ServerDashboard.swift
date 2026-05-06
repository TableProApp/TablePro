import AppKit
import Foundation

extension MainContentCoordinator {
    /// Open (or focus) the Server Dashboard tab for this connection.
    ///
    /// Singleton per connection. Resolution order:
    /// 1. If any window for this connection already hosts a Server Dashboard
    ///    tab, focus that window.
    /// 2. If this window's tabManager is empty, add the dashboard tab locally.
    /// 3. Otherwise open a new native window tab so the current tab's content
    ///    is preserved.
    func showServerDashboard() {
        if let existing = Self.coordinator(forConnection: connectionId, tabMatching: {
            $0.tabType == .serverDashboard
        }) {
            existing.contentWindow?.makeKeyAndOrderFront(nil)
            return
        }

        if tabManager.tabs.isEmpty {
            tabManager.addServerDashboardTab()
            return
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .serverDashboard,
            databaseName: activeDatabaseName
        )
        WindowManager.shared.openTab(payload: payload)
    }
}
