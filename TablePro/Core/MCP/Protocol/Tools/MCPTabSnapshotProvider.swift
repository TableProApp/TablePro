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
    static let openPollInterval: Duration = .milliseconds(50)
    static let openTimeout: Duration = .seconds(8)

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
        return snapshots.sorted { lhs, rhs in
            if lhs.connectionName != rhs.connectionName {
                return lhs.connectionName.localizedStandardCompare(rhs.connectionName) == .orderedAscending
            }
            if lhs.displayTitle != rhs.displayTitle {
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
            return lhs.tabId.uuidString < rhs.tabId.uuidString
        }
    }

    static func readableSnapshots(
        context: MCPRequestContext,
        services: MCPToolServices
    ) async -> [MCPTabSnapshot] {
        let readable = await MCPToolAuthorization.readableConnectionIds(context: context, services: services)
        let snapshots = await MainActor.run { collectTabSnapshots() }
        return snapshots.filter { readable.contains($0.connectionId) }
    }

    static func awaitTab(
        connectionId: UUID,
        tableName: String?,
        clock: ContinuousClock = ContinuousClock()
    ) async -> MCPTabSnapshot? {
        let deadline = clock.now.advanced(by: openTimeout)
        while clock.now < deadline {
            let snapshots = await MainActor.run { collectTabSnapshots() }
            let candidates = snapshots.filter { $0.connectionId == connectionId }
            if let tableName {
                if let match = candidates.first(where: { $0.tableName == tableName }) {
                    return match
                }
            } else if let match = candidates.first(where: \.isActive) ?? candidates.first {
                return match
            }
            try? await Task.sleep(for: openPollInterval)
        }
        return nil
    }

    static func encode(_ snapshot: MCPTabSnapshot) -> JsonValue {
        var fields: [String: JsonValue] = [
            "connection_id": .string(snapshot.connectionId.uuidString),
            "connection_name": .string(snapshot.connectionName),
            "tab_id": .string(snapshot.tabId.uuidString),
            "tab_type": .string(snapshot.tabType),
            "display_title": .string(snapshot.displayTitle),
            "is_active": .bool(snapshot.isActive)
        ]
        if let table = snapshot.tableName {
            fields["table_name"] = .string(table)
        }
        if let database = snapshot.databaseName {
            fields["database_name"] = .string(database)
        }
        if let schema = snapshot.schemaName {
            fields["schema_name"] = .string(schema)
        }
        if let windowId = snapshot.windowId {
            fields["window_id"] = .string(windowId.uuidString)
        }
        return .object(fields)
    }

    static let tabSchema: JsonValue = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.string(String(localized: "Connection the tab belongs to")),
            "connection_name": MCPToolSchema.string(String(localized: "Connection display name")),
            "tab_id": MCPToolSchema.string(String(localized: "Tab id, accepted by focus_query_tab")),
            "tab_type": MCPToolSchema.string(String(localized: "Kind of tab")),
            "display_title": MCPToolSchema.string(String(localized: "Tab label")),
            "is_active": MCPToolSchema.boolean(String(localized: "Whether the tab is selected in its window")),
            "table_name": MCPToolSchema.string(String(localized: "Table the tab shows")),
            "database_name": MCPToolSchema.string(String(localized: "Database the tab is on")),
            "schema_name": MCPToolSchema.string(String(localized: "Schema the tab is on")),
            "window_id": MCPToolSchema.string(String(localized: "Window id, stable across tools"))
        ],
        required: ["connection_id", "connection_name", "tab_id", "tab_type", "display_title", "is_active"]
    )
}

private extension TabType {
    var snapshotName: String {
        switch self {
        case .query: "query"
        case .table: "table"
        case .createTable: "createTable"
        case .erDiagram: "erDiagram"
        case .serverDashboard: "serverDashboard"
        case .insights: "insights"
        case .usersRoles: "usersRoles"
        case .objectSource: "objectSource"
        }
    }
}
