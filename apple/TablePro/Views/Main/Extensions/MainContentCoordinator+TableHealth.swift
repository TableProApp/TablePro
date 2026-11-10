import Foundation

extension MainContentCoordinator {
    // The entry on screen, not the browse cursor, which lags a switch to it.
    func showTableHealth() {
        let databaseName = newTabDatabaseName
        guard !databaseName.isEmpty else { return }
        let checksDatabase: (QueryTab) -> Bool = {
            $0.tabType == .tableHealth && $0.tableContext.databaseName == databaseName
        }

        if let existing = Self.coordinator(forConnection: connectionId, tabMatching: checksDatabase),
           let match = existing.tabManager.tabs.first(where: checksDatabase) {
            existing.selectTabAndFocusWindow(match.id)
            return
        }

        if tabManager.tabs.isEmpty {
            tabManager.addTableHealthTab(databaseName: databaseName)
            return
        }

        WindowManager.shared.openTab(payload: EditorTabPayload(
            connectionId: connection.id,
            tabType: .tableHealth,
            databaseName: databaseName
        ))
    }
}
