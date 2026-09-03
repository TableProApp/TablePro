import Foundation
import os
import TableProPluginKit

/// The MCP wire encoding over `DatabaseAccessBridge`.
///
/// Connecting, switching container and running a statement live one layer down, where every
/// programmatic caller reaches them. What is left here is the part that is genuinely MCP's: turning
/// those results into the `JsonValue` shapes the tools and resources are specified in.
public actor MCPConnectionBridge {
    static let logger = Logger(subsystem: "com.TablePro", category: "MCPConnectionBridge")

    private let access = DatabaseAccessBridge()

    public init() {}

    func listConnections(principal: MCPPrincipal) async -> JsonValue {
        await listConnections(access: principal.connectionAccess)
    }

    func listConnections() async -> JsonValue {
        await listConnections(access: .all)
    }

    private func listConnections(access: ConnectionAccess) async -> JsonValue {
        let (connections, activeSessions) = await MainActor.run {
            let defaultPolicy = AppSettingsManager.shared.ai.defaultConnectionPolicy
            let conns = ConnectionStorage.shared.loadConnections()
                .filter { $0.externalAccess != .blocked }
                .filter { ($0.aiPolicy ?? defaultPolicy) != .never }
                .filter { access.allows($0.id) }
            return (conns, DatabaseManager.shared.activeSessions)
        }

        let items: [JsonValue] = connections
            .sorted { lhs, rhs in
                lhs.name == rhs.name
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map { conn in
                let session = activeSessions[conn.id]
                let policy = conn.aiPolicy ?? AIConnectionPolicy.askEachTime
                return .object([
                    "id": .string(conn.id.uuidString),
                    "name": .string(conn.name),
                    "type": .string(conn.type.rawValue),
                    "host": .string(conn.host),
                    "port": .int(conn.port),
                    "database": .string(session?.resolvedBrowseDatabase ?? conn.database),
                    "is_connected": .bool(session?.status.isConnected ?? false),
                    "ai_policy": .string(policy.rawValue),
                    "external_access": .string(conn.externalAccess.rawValue),
                    "safe_mode": .string(conn.safeModeLevel.rawValue)
                ])
            }

        return .object(["connections": .array(items)])
    }

    func connect(connectionId: UUID) async throws -> JsonValue {
        let snapshot = try await access.connect(connectionId: connectionId)

        var result: [String: JsonValue] = [
            "status": .string("connected"),
            "connection_id": .string(connectionId.uuidString),
            "current_database": .string(snapshot.database)
        ]
        if let version = snapshot.serverVersion {
            result["server_version"] = .string(version)
        }
        if let schema = snapshot.schema {
            result["current_schema"] = .string(schema)
        }
        return .object(result)
    }

    func disconnect(connectionId: UUID) async throws -> JsonValue {
        try await access.disconnect(connectionId: connectionId)
        return .object([
            "status": .string("disconnected"),
            "connection_id": .string(connectionId.uuidString)
        ])
    }

    func getConnectionStatus(connectionId: UUID) async throws -> JsonValue {
        let snapshot = try await access.connectionStatus(connectionId: connectionId)

        let statusString: String
        var errorDetail: JsonValue?
        switch snapshot.status {
        case .connected: statusString = "connected"
        case .connecting: statusString = "connecting"
        case .disconnected: statusString = "disconnected"
        case .error(let message):
            statusString = "error"
            errorDetail = .string(MCPErrorRedactor.redact(message))
        }

        var result: [String: JsonValue] = [
            "status": .string(statusString),
            "connection_id": .string(connectionId.uuidString),
            "current_database": .string(snapshot.database),
            "connected_at": .string(Self.iso8601.withLockUnchecked { $0.string(from: snapshot.connectedAt) }),
            "last_active_at": .string(Self.iso8601.withLockUnchecked { $0.string(from: snapshot.lastActiveAt) })
        ]
        if let schema = snapshot.schema {
            result["current_schema"] = .string(schema)
        }
        if let version = snapshot.serverVersion {
            result["server_version"] = .string(version)
        }
        if let errorDetail {
            result["error"] = errorDetail
        }
        return .object(result)
    }

    func resolveScope(connectionId: UUID, database: String?, schema: String?) async throws -> DatabaseScope {
        try await access.resolveScope(connectionId: connectionId, database: database, schema: schema)
    }

    func switchDatabase(connectionId: UUID, database: String) async throws -> JsonValue {
        try await access.switchDatabase(connectionId: connectionId, database: database)
        return .object([
            "status": .string("switched"),
            "connection_id": .string(connectionId.uuidString),
            "current_database": .string(database)
        ])
    }

    func switchSchema(connectionId: UUID, schema: String) async throws -> JsonValue {
        try await access.switchSchema(connectionId: connectionId, schema: schema)
        return .object([
            "status": .string("switched"),
            "connection_id": .string(connectionId.uuidString),
            "current_schema": .string(schema)
        ])
    }

    func executeQuery(
        scope: DatabaseScope,
        query: String,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: MCPCancellationToken?
    ) async throws -> JsonValue {
        let outcome = try await runStatement(
            scope: scope,
            query: query,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation
        )
        return Self.encode(
            result: outcome.result,
            scope: scope,
            executionTimeMs: outcome.executionTimeMs
        )
    }

    func runStatement(
        scope: DatabaseScope,
        query: String,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: MCPCancellationToken?
    ) async throws -> (result: QueryResult, executionTimeMs: Double) {
        let outcome = try await access.runStatement(
            scope: scope,
            query: query,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation
        )
        return (outcome.result, outcome.executionTimeMs)
    }

    static func encode(result: QueryResult, scope: DatabaseScope, executionTimeMs: Double) -> JsonValue {
        var response: [String: JsonValue] = [
            "columns": .array(result.columns.map { .string($0) }),
            "rows": .array(result.rows.map { row in .array(row.map(cellValue)) }),
            "row_count": .int(result.rows.count),
            "rows_affected": .int(result.rowsAffected),
            "execution_time_ms": .double(executionTimeMs),
            "is_truncated": .bool(result.isTruncated),
            "database": .string(scope.database)
        ]
        if let schema = scope.schema {
            response["schema"] = .string(schema)
        }
        if let statusMessage = result.statusMessage {
            response["status_message"] = .string(statusMessage)
        }
        return .object(response)
    }

    static func cellValue(_ cell: PluginCellValue) -> JsonValue {
        switch cell {
        case .null: return .null
        case .text(let value): return .string(value)
        case .bytes(let data): return .string(data.base64EncodedString())
        }
    }

    static let iso8601 = OSAllocatedUnfairLock(uncheckedState: ISO8601DateFormatter())

    func resolveDriver(_ connectionId: UUID) async throws -> (DatabaseDriver, DatabaseType) {
        try await access.resolveDriver(connectionId)
    }

    @discardableResult
    func ensureConnected(_ connectionId: UUID) async throws -> DatabaseType {
        try await access.ensureConnected(connectionId)
    }

    func resolveConnection(_ connectionId: UUID) async throws -> DatabaseConnection {
        try await access.resolveConnection(connectionId)
    }

    static func stripTrailingSemicolons(_ query: String) -> String {
        DatabaseAccessBridge.stripTrailingSemicolons(query)
    }
}

extension MCPCancellationToken: StatementCancellationSignal {
    func onCancelRequested(_ handler: @escaping @Sendable () async -> Void) async {
        await onCancel { _ in await handler() }
    }
}
