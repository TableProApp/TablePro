import AppKit
import Foundation

extension MainContentCoordinator {
    /// Open (or focus) the Table Health tab for this connection, one per connection like the Server Dashboard.
    func showTableHealth() {
        if let existing = Self.coordinator(forConnection: connectionId, tabMatching: {
            $0.tabType == .tableHealth
        }), let match = existing.tabManager.tabs.first(where: { $0.tabType == .tableHealth }) {
            existing.selectTabAndFocusWindow(match.id)
            return
        }

        if tabManager.tabs.isEmpty {
            tabManager.addTableHealthTab()
            return
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .tableHealth,
            databaseName: browseDatabaseName
        )
        WindowManager.shared.openTab(payload: payload)
    }

    func openTableHealthFinding(_ finding: TableHealthFinding, schemaNamesDatabase: Bool) {
        if schemaNamesDatabase {
            openTableTab(finding.table, database: finding.schema)
        } else {
            openTableTab(finding.table, schema: finding.schema)
        }
    }

    /// Puts the fix in an editor tab and stops there: the user reads it and runs it themselves.
    func openTableHealthFix(_ finding: TableHealthFinding, schemaNamesDatabase: Bool) {
        openQuery(
            finding.fixSQL,
            on: connectionId,
            databaseName: schemaNamesDatabase ? finding.schema : browseDatabaseName,
            intent: .loadIntoFrontTab
        )
    }
}
