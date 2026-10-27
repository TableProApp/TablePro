import AppKit
import Foundation
import TableProMCP

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

    /// A database or schema the caller left out means the one being browsed, which is where the
    /// open put the tab. Matching the name alone returned whichever same-named table sorted first,
    /// so an agent asking for `tenant_b.orders` was handed the id of `tenant_a.orders`.
    static func awaitTab(
        connectionId: UUID,
        tableName: String?,
        databaseName: String? = nil,
        schemaName: String? = nil,
        clock: ContinuousClock = ContinuousClock()
    ) async -> MCPTabSnapshot? {
        let deadline = clock.now.advanced(by: openTimeout)
        while clock.now < deadline {
            let match = await MainActor.run { () -> MCPTabSnapshot? in
                let candidates = collectTabSnapshots().filter { $0.connectionId == connectionId }
                guard let tableName else {
                    return candidates.first(where: \.isActive) ?? candidates.first
                }
                let databaseManager = DatabaseManager.shared
                return firstTable(
                    in: candidates,
                    matching: databaseManager.requestedTableIdentity(
                        table: tableName, database: databaseName, schema: schemaName, for: connectionId
                    ),
                    browseDatabase: databaseManager.activeSessions[connectionId]?.resolvedBrowseDatabase ?? ""
                )
            }
            if let match {
                return match
            }
            try? await Task.sleep(for: openPollInterval)
        }
        return nil
    }

    static func firstTable(
        in snapshots: [MCPTabSnapshot],
        matching wanted: TableTabIdentity,
        browseDatabase: String
    ) -> MCPTabSnapshot? {
        snapshots.first { snapshot in
            guard snapshot.tabType == TabType.table.snapshotName,
                  let table = snapshot.tableName
            else { return false }
            let database = snapshot.databaseName.flatMap { $0.isEmpty ? nil : $0 } ?? browseDatabase
            return TableTabIdentity(table: table, database: database, schema: snapshot.schemaName) == wanted
        }
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
        case .versionHistory: "versionHistory"
        case .tableListing: "tableListing"
        }
    }
}
