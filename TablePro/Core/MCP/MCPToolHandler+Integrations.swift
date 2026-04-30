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
        let blockedConnectionIds = await MainActor.run { Self.blockedExternalConnectionIds() }
        let allowed = token?.allowedConnectionIds
        let filtered = snapshots.filter { snapshot in
            guard !blockedConnectionIds.contains(snapshot.connectionId) else { return false }
            if let allowed, !allowed.contains(snapshot.connectionId) { return false }
            return true
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
        let since = args?["since"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        let until = args?["until"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }

        if let since, let until, since > until {
            throw MCPError.invalidParams("'since' must be less than or equal to 'until'")
        }

        let blockedConnectionIds = await MainActor.run { Self.blockedExternalConnectionIds() }

        let connectionId: UUID?
        if let connectionIdString {
            guard let parsed = UUID(uuidString: connectionIdString) else {
                throw MCPError.invalidParams("Invalid UUID for parameter: connection_id")
            }
            if let token { try checkTokenConnectionAccess(token, connectionId: parsed) }
            if blockedConnectionIds.contains(parsed) {
                throw MCPError.forbidden(
                    String(localized: "External access is disabled for this connection")
                )
            }
            connectionId = parsed
        } else {
            connectionId = nil
        }

        let allowedConnectionIds = await resolveHistoryAllowlist(
            token: token,
            scopedConnectionId: connectionId,
            blockedConnectionIds: blockedConnectionIds
        )

        let entries = await QueryHistoryStorage.shared.fetchHistory(
            limit: limit,
            offset: 0,
            connectionId: connectionId,
            searchText: query.isEmpty ? nil : query,
            dateFilter: .all,
            since: since,
            until: until,
            allowedConnectionIds: allowedConnectionIds
        )

        let payload = entries.map { entry -> JSONValue in
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
        try await authGuard.checkExternalAccessLevel(connectionId: connectionId, requires: .readOnly)

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
        try await authGuard.checkExternalAccessLevel(connectionId: connectionId, requires: .readOnly)

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

        let resolved = await MainActor.run { () -> (hasWindow: Bool, windowId: UUID?, connectionId: UUID?)? in
            for snapshot in Self.collectTabSnapshots() where snapshot.tabId == tabId {
                return (snapshot.window != nil, snapshot.windowId, snapshot.connectionId)
            }
            return nil
        }

        guard let resolved, resolved.hasWindow else {
            throw MCPError.notFound("tab")
        }

        guard let connectionId = resolved.connectionId else {
            throw MCPError.notFound("connection")
        }
        if let token { try checkTokenConnectionAccess(token, connectionId: connectionId) }
        try await authGuard.checkExternalAccessLevel(connectionId: connectionId, requires: .readOnly)

        let raised = await MainActor.run { () -> Bool in
            for snapshot in Self.collectTabSnapshots() where snapshot.tabId == tabId {
                guard let window = snapshot.window else { return false }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                return true
            }
            return false
        }

        guard raised else {
            throw MCPError.notFound("tab")
        }

        var dict: [String: JSONValue] = [
            "status": "focused",
            "tab_id": .string(tabId.uuidString),
            "connection_id": .string(connectionId.uuidString)
        ]
        if let windowId = resolved.windowId {
            dict["window_id"] = .string(windowId.uuidString)
        }

        return MCPToolResult(content: [.text(encodeJSON(.object(dict)))], isError: nil)
    }

    // MARK: - Helpers

    private func resolveHistoryAllowlist(
        token: MCPAuthToken?,
        scopedConnectionId: UUID?,
        blockedConnectionIds: Set<UUID>
    ) async -> Set<UUID>? {
        if scopedConnectionId != nil {
            return nil
        }
        if let tokenAllowed = token?.allowedConnectionIds {
            return tokenAllowed.subtracting(blockedConnectionIds)
        }
        guard !blockedConnectionIds.isEmpty else { return nil }
        let allConnectionIds = await MainActor.run {
            Set(ConnectionStorage.shared.loadConnections().map(\.id))
        }
        return allConnectionIds.subtracting(blockedConnectionIds)
    }

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

    @MainActor
    static func blockedExternalConnectionIds() -> Set<UUID> {
        let connections = ConnectionStorage.shared.loadConnections()
        return Set(connections.filter { $0.externalAccess == .blocked }.map(\.id))
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
