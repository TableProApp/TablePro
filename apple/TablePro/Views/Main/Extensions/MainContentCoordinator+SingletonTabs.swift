import Foundation

extension MainContentCoordinator {
    // Focuses the connection's open tab of this type, else adds it here when this window is empty,
    // else opens a window tab so the current tab stays.
    func showSingletonTab(_ tabType: TabType) {
        if let existing = Self.coordinator(forConnection: connectionId, tabMatching: { $0.tabType == tabType }),
           let match = existing.tabManager.tabs.first(where: { $0.tabType == tabType }) {
            existing.selectTabAndFocusWindow(match.id)
            return
        }

        if tabManager.tabs.isEmpty {
            tabManager.addSingletonTab(tabType)
            return
        }

        WindowManager.shared.openTab(payload: EditorTabPayload(
            connectionId: connection.id,
            tabType: tabType,
            databaseName: browseDatabaseName
        ))
    }
}
