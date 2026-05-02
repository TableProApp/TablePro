import AppKit
import Foundation

struct MCPTabSnapshot {
    let tabId: UUID
    let connectionId: UUID
    let connectionName: String
    let tabType: String
    let tableName: String?
    let databaseName: String?
    let schemaName: String?
    let displayTitle: String
    let windowId: UUID?
    let isActive: Bool
    weak var window: NSWindow?
}

enum MCPTabSnapshotProvider {
    @MainActor
    static func collectTabSnapshots() -> [MCPTabSnapshot] {
        let connections = ConnectionStorage.shared.loadConnections()
        let connectionsById = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })

        var snapshots: [MCPTabSnapshot] = []
        for coordinator in MainContentCoordinator.allActiveCoordinators() {
            let connectionName = connectionsById[coordinator.connectionId]?.name
                ?? coordinator.connection.name
            let selectedId = coordinator.tabManager.selectedTabId
            for tab in coordinator.tabManager.tabs {
                snapshots.append(MCPTabSnapshot(
                    tabId: tab.id,
                    connectionId: coordinator.connectionId,
                    connectionName: connectionName,
                    tabType: tab.tabType.snapshotName,
                    tableName: tab.tableContext.tableName,
                    databaseName: tab.tableContext.databaseName,
                    schemaName: tab.tableContext.schemaName,
                    displayTitle: tab.title,
                    windowId: coordinator.windowId,
                    isActive: tab.id == selectedId,
                    window: coordinator.contentWindow
                ))
            }
        }
        return snapshots
    }

    @MainActor
    static func blockedExternalConnectionIds() -> Set<UUID> {
        let connections = ConnectionStorage.shared.loadConnections()
        return Set(connections.filter { $0.externalAccess == .blocked }.map(\.id))
    }
}

private extension TabType {
    var snapshotName: String {
        switch self {
        case .query: "query"
        case .table: "table"
        case .createTable: "createTable"
        case .erDiagram: "erDiagram"
        case .serverDashboard: "serverDashboard"
        case .terminal: "terminal"
        }
    }
}
