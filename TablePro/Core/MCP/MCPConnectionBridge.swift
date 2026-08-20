import Foundation
import os
import TableProPluginKit

public actor MCPConnectionBridge {
    static let logger = Logger(subsystem: "com.TablePro", category: "MCPConnectionBridge")

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
        let connection = try await resolveConnection(connectionId)

        let alreadyLive = await MainActor.run {
            DatabaseManager.shared.activeSessions[connectionId]?.driver != nil
        }
        if !alreadyLive {
            try await DatabaseManager.shared.ensureConnected(connection)
        }

        let snapshot = await MainActor.run { () -> (String?, String, String?)? in
            guard let session = DatabaseManager.shared.activeSessions[connectionId],
                  session.driver != nil
            else {
                return nil
            }
            return (session.driver?.serverVersion, session.resolvedBrowseDatabase, session.browseSchema)
        }

        guard let snapshot else {
            throw MCPDataLayerError.notConnected(connectionId)
        }

        var result: [String: JsonValue] = [
            "status": .string("connected"),
            "connection_id": .string(connectionId.uuidString),
            "current_database": .string(snapshot.1)
        ]
        if let version = snapshot.0 {
            result["server_version"] = .string(version)
        }
        if let schema = snapshot.2 {
            result["current_schema"] = .string(schema)
        }
        return .object(result)
    }

    func disconnect(connectionId: UUID) async throws -> JsonValue {
        let sessionExists = await MainActor.run {
            DatabaseManager.shared.activeSessions[connectionId] != nil
        }
        guard sessionExists else {
            throw MCPDataLayerError.notConnected(connectionId)
        }
        await DatabaseManager.shared.disconnectSession(connectionId)
        return .object([
            "status": .string("disconnected"),
            "connection_id": .string(connectionId.uuidString)
        ])
    }

    struct ConnectionStatusSnapshot: Sendable {
        let status: ConnectionStatus
        let database: String
        let schema: String?
        let serverVersion: String?
        let connectedAt: Date
        let lastActiveAt: Date
    }

    func getConnectionStatus(connectionId: UUID) async throws -> JsonValue {
        let snapshot = await MainActor.run { () -> ConnectionStatusSnapshot? in
            guard let session = DatabaseManager.shared.activeSessions[connectionId] else { return nil }
            return ConnectionStatusSnapshot(
                status: session.status,
                database: session.resolvedBrowseDatabase,
                schema: session.browseSchema,
                serverVersion: session.driver?.serverVersion,
                connectedAt: session.connectedAt,
                lastActiveAt: session.lastActiveAt
            )
        }

        guard let snapshot else {
            throw MCPDataLayerError.notConnected(connectionId)
        }

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
            "connected_at": .string(Self.iso8601.string(from: snapshot.connectedAt)),
            "last_active_at": .string(Self.iso8601.string(from: snapshot.lastActiveAt))
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
        try await ensureConnected(connectionId)
        return try await MainActor.run {
            guard let scope = DatabaseManager.shared.resolvedScope(
                database: database,
                schema: schema,
                for: connectionId
            ) else {
                throw MCPDataLayerError.invalidArgument(
                    String(localized: "No database to run against. Pass a database name.")
                )
            }
            return scope
        }
    }

    func switchDatabase(connectionId: UUID, database: String) async throws -> JsonValue {
        try await DatabaseManager.shared.switchDatabase(to: database, for: connectionId)
        return .object([
            "status": .string("switched"),
            "connection_id": .string(connectionId.uuidString),
            "current_database": .string(database)
        ])
    }

    func switchSchema(connectionId: UUID, schema: String) async throws -> JsonValue {
        try await DatabaseManager.shared.switchSchema(to: schema, for: connectionId)
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
        let databaseType = try await ensureConnected(scope.connectionId)
        let normalizedQuery = Self.stripTrailingSemicolons(query)
        let classification = QueryClassifier.classify(normalizedQuery, databaseType: databaseType)
        let hasReturning = normalizedQuery.range(
            of: #"\bRETURNING\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let shouldCap = classification.tier == .safe || hasReturning
        let connectionId = scope.connectionId
        let policy: DriverCancellationPolicy = classification.tier == .safe ? .cancellableRead : .protectedWrite

        if let cancellation {
            await cancellation.onCancel { _ in
                await MainActor.run {
                    try? DatabaseManager.shared.cancelRunningQuery(for: connectionId, reach: .userStop)
                }
            }
        }

        let route = await MainActor.run { DatabaseManager.shared.executionRoute(for: scope) }
        let startTime = CFAbsoluteTimeGetCurrent()

        let result = try await withThrowingTaskGroup(of: QueryResult.self) { group in
            group.addTask {
                try await DatabaseManager.shared.withScopedDriver(
                    scope: scope,
                    route: route,
                    cancellation: policy
                ) { driver in
                    if shouldCap {
                        return try await driver.executeUserQuery(
                            query: normalizedQuery,
                            rowCap: maxRows,
                            parameters: nil
                        )
                    }
                    return try await driver.execute(query: normalizedQuery)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                await MainActor.run {
                    try? DatabaseManager.shared.cancelRunningQuery(for: connectionId, reach: .userStop)
                }
                throw MCPDataLayerError.timeout(
                    String(
                        format: String(localized: "Query timed out after %d seconds"),
                        timeoutSeconds
                    )
                )
            }
            guard let first = try await group.next() else {
                throw MCPDataLayerError.dataSourceError("No result from query execution")
            }
            group.cancelAll()
            return first
        }

        return (result, (CFAbsoluteTimeGetCurrent() - startTime) * 1_000)
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

    static let iso8601 = ISO8601DateFormatter()

    func resolveDriver(_ connectionId: UUID) async throws -> (DatabaseDriver, DatabaseType) {
        let pending: DatabaseConnection? = await MainActor.run {
            switch DatabaseManager.shared.connectionState(connectionId) {
            case .live: return nil
            case .stored(let connection): return connection
            case .unknown: return nil
            }
        }
        if let pending {
            try await DatabaseManager.shared.ensureConnected(pending)
        }
        return try await MainActor.run {
            switch DatabaseManager.shared.connectionState(connectionId) {
            case .live(let driver, let session):
                return (driver, session.connection.type)
            case .stored, .unknown:
                throw MCPDataLayerError.notConnected(connectionId)
            }
        }
    }

    @discardableResult
    func ensureConnected(_ connectionId: UUID) async throws -> DatabaseType {
        let (_, databaseType) = try await resolveDriver(connectionId)
        return databaseType
    }

    func resolveConnection(_ connectionId: UUID) async throws -> DatabaseConnection {
        try await MainActor.run {
            let connections = ConnectionStorage.shared.loadConnections()
            guard let connection = connections.first(where: { $0.id == connectionId }) else {
                throw MCPDataLayerError.notFound(
                    String(localized: "No saved connection has that id.")
                )
            }
            return connection
        }
    }

    static func stripTrailingSemicolons(_ query: String) -> String {
        var result = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(";") {
            result = String(result.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}
