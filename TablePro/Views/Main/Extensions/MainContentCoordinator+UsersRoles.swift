import AppKit
import Foundation

extension MainContentCoordinator {
    func showUsersAndRoles() {
        if let existing = Self.coordinator(forConnection: connectionId, tabMatching: {
            $0.tabType == .usersRoles
        }), let match = existing.tabManager.tabs.first(where: { $0.tabType == .usersRoles }) {
            /// Selecting it, not just raising its window. An editor tab used to be a window, so
            /// raising the window was the whole of showing the tab; now a window holds every tab
            /// and the command did nothing whenever the tab it names is not the one in front.
            existing.selectTabAndFocusWindow(match.id)
            return
        }

        if tabManager.tabs.isEmpty {
            tabManager.addUsersRolesTab()
            return
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .usersRoles,
            databaseName: browseDatabaseName
        )
        WindowManager.shared.openTab(payload: payload)
    }
}
