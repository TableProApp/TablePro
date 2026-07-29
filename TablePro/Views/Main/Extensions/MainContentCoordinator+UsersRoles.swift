import AppKit
import Foundation

extension MainContentCoordinator {
    func showUsersAndRoles() {
        if let existing = Self.coordinator(forConnection: connectionId, tabMatching: {
            $0.tabType == .usersRoles
        }) {
            existing.contentWindow?.makeKeyAndOrderFront(nil)
            return
        }

        if tabManager.tabs.isEmpty {
            tabManager.addUsersRolesTab()
            return
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .usersRoles,
            databaseName: activeDatabaseName
        )
        WindowManager.shared.openTab(payload: payload)
    }
}
