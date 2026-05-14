import AppKit
import Foundation

extension MainContentCoordinator {
    /// Open (or focus) the Server Dashboard tab for this connection. Singleton
    /// per connection: `addServerDashboardTab` selects the existing tab when
    /// one is already open.
    func showServerDashboard() {
        tabManager.addServerDashboardTab()
    }
}
