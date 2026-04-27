//
//  MCPToolHandler+Integrations.swift
//  TablePro
//

import AppKit
import Foundation

extension MCPToolHandler {
    // MARK: - list_recent_tabs

    func handleListRecentTabs(_ args: JSONValue?, token: MCPAuthToken?) async throws -> MCPToolResult {
        let limit = optionalInt(args, key: "limit", default: 20, clamp: 1...500)

        let snapshots = await MainActor.run { Self.collectTabSnapshots() }
        let allowed = token?.allowedConnectionIds
        let filtered: [TabSnapshot]
        if let allowed {
            filtered = snapshots.filter { allowed.contains($0.connectionId) }
        } else {
            filtered = snapshots
        }

        let trimmed = Array(filtered.prefix(limit))
        let payload = trimmed.map { snapshot -> JSONValue in
            var dict: [String: JSONValue] = [
                "connection_id": .string(snapshot.connectionId.uuidString),
                "connection_name": .string(snapshot.connectionName),
                "tab_id": .string(snapshot.tabId.uuidString),
                "tab_type": .string(snapshot.tabType),
                "display_title": .string(snapshot.displayTitle),
                "is_active": .bool(snapshot.isActive)
            ]
            if let table = snapshot.tableName {
                dict["table_name"] = .string(table)
            }
            if let database = snapshot.databaseName {
                dict["database_name"] = .string(database)
            }
            if let schema = snapshot.schemaName {
                dict["schema_name"] = .string(schema)
            }
            if let windowId = snapshot.windowId {
                dict["window_id"] = .string(windowId.uuidString)
            }
            return .object(dict)
        }

        return MCPToolResult(content: [.text(encodeJSON(.object(["tabs": .array(payload)])))], isError: nil)
    }

    // MARK: - search_query_history

    func handleSearchQueryHistory(_ args: JSONValue?, token: MCPAuthToken?) async throws -> MCPToolResult {
        let query = try requireString(args, key: "query")
        let connectionIdString = optionalString(args, key: "connection_id")
        let limit = optionalInt(args, key: "limit", default: 50, clamp: 1...500)

        let connectionId: UUID?
        if let connectionIdString {
            guard let parsed = UUID(uuidString: connectionIdString) else {
                throw MCPError.invalidParams("Invalid UUID for parameter: connection_id")
            }
            if let token { try checkTokenConnectionAccess(token, connectionId: parsed) }
            connectionId = parsed
        } else {
            connectionId = nil
        }

        let entries = await QueryHistoryStorage.shared.fetchHistory(
            limit: limit,
            offset: 0,
            connectionId: connectionId,
            searchText: query.isEmpty ? nil : query,
            dateFilter: .all
        )

        let allowed = token?.allowedConnectionIds
        let filtered: [QueryHistoryEntry]
        if let allowed {
            filtered = entries.filter { allowed.contains($0.connectionId) }
        } else {
            filtered = entries
        }

        let payload = filtered.map { entry -> JSONValue in
            var dict: [String: JSONValue] = [
                "id": .string(entry.id.uuidString),
                "query": .string(entry.query),
                "connection_id": .string(entry.connectionId.uuidString),
                "database_name": .string(entry.databaseName),
                "executed_at": .double(entry.executedAt.timeIntervalSince1970),
                "execution_time_ms": .double(entry.executionTime * 1_000),
                "row_count": .int(entry.rowCount),
                "was_successful": .bool(entry.wasSuccessful)
            ]
            if let error = entry.errorMessage {
                dict["error_message"] = .string(error)
            }
            return .object(dict)
        }

        return MCPToolResult(content: [.text(encodeJSON(.object(["entries": .array(payload)])))], isError: nil)
    }

    // MARK: - open_connection_window

    func handleOpenConnectionWindow(_ args: JSONValue?, token: MCPAuthToken?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await ensureConnectionExists(connectionId)

        let windowId = await MainActor.run { () -> UUID in
            let payload = EditorTabPayload(
                connectionId: connectionId,
                tabType: .query,
                intent: .restoreOrDefault
            )
            WindowManager.shared.openTab(payload: payload)
            NSApp.activate(ignoringOtherApps: true)
            return payload.id
        }

        let result: JSONValue = .object([
            "status": "opened",
            "connection_id": .string(connectionId.uuidString),
            "window_id": .string(windowId.uuidString)
        ])
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    // MARK: - open_table_tab

    func handleOpenTableTab(_ args: JSONValue?, token: MCPAuthToken?) async throws -> MCPToolResult {
        let connectionId = try requireUUID(args, key: "connection_id")
        let tableName = try requireString(args, key: "table_name")
        let databaseName = optionalString(args, key: "database_name")
        let schemaName = optionalString(args, key: "schema_name")

        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await ensureConnectionExists(connectionId)

        let windowId = await MainActor.run { () -> UUID in
            let payload = EditorTabPayload(
                connectionId: connectionId,
                tabType: .table,
                tableName: tableName,
                databaseName: databaseName,
                schemaName: schemaName,
                intent: .openContent
            )
            WindowManager.shared.openTab(payload: payload)
            NSApp.activate(ignoringOtherApps: true)
            return payload.id
        }

        let result: JSONValue = .object([
            "status": "opened",
            "connection_id": .string(connectionId.uuidString),
            "table_name": .string(tableName),
            "window_id": .string(windowId.uuidString)
        ])
        return MCPToolResult(content: [.text(encodeJSON(result))], isError: nil)
    }

    // MARK: - focus_query_tab

    func handleFocusQueryTab(_ args: JSONValue?, token: MCPAuthToken?) async throws -> MCPToolResult {
        let tabId = try requireUUID(args, key: "tab_id")

        let outcome = await MainActor.run { () -> (Bool, UUID?, UUID?) in
            for snapshot in Self.collectTabSnapshots() where snapshot.tabId == tabId {
                if let window = snapshot.window {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    return (true, snapshot.windowId, snapshot.connectionId)
                }
                return (false, snapshot.windowId, snapshot.connectionId)
            }
            return (false, nil, nil)
        }

        guard outcome.0 else {
            throw MCPError.notFound("tab")
        }

        if let connectionId = outcome.2, let token {
            try checkTokenConnectionAccess(token, connectionId: connectionId)
        }

        var dict: [String: JSONValue] = [
            "status": "focused",
            "tab_id": .string(tabId.uuidString)
        ]
        if let windowId = outcome.1 {
            dict["window_id"] = .string(windowId.uuidString)
        }
        if let connectionId = outcome.2 {
            dict["connection_id"] = .string(connectionId.uuidString)
        }

        return MCPToolResult(content: [.text(encodeJSON(.object(dict)))], isError: nil)
    }

    // MARK: - Helpers

    private func ensureConnectionExists(_ connectionId: UUID) async throws {
        let exists = await MainActor.run {
            ConnectionStorage.shared.loadConnections().contains { $0.id == connectionId }
        }
        guard exists else {
            throw MCPError.notFound("connection")
        }
    }

    @MainActor
    static func collectTabSnapshots() -> [TabSnapshot] {
        let connections = ConnectionStorage.shared.loadConnections()
        let connectionsById = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })

        var snapshots: [TabSnapshot] = []
        for coordinator in MainContentCoordinator.allActiveCoordinators() {
            let connectionName = connectionsById[coordinator.connectionId]?.name
                ?? coordinator.connection.name
            let selectedId = coordinator.tabManager.selectedTabId
            for tab in coordinator.tabManager.tabs {
                snapshots.append(TabSnapshot(
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
}

struct TabSnapshot {
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
