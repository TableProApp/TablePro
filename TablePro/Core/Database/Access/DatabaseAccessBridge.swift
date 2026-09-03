//
//  DatabaseAccessBridge.swift
//  TablePro
//

import Foundation
import os

/// Connecting, switching container and running one statement, for a caller that is not a person
/// clicking in the app.
///
/// MCP, the AI assistant and AppleScript all need the same six operations against `DatabaseManager`
/// and they must agree on every one of them, so they share this rather than each reaching into the
/// manager on its own terms. Everything here is typed: JSON is a wire format that belongs to the
/// MCP transport, and `MCPConnectionBridge` is the layer that encodes these results into it.
///
/// Authorization is deliberately not here. A caller runs `ExternalStatementGate.authorize` first,
/// which is where safe mode, the connection's external-access level and the destructive-statement
/// confirmation live. This type would otherwise be the second place that decides, and two places
/// that decide are one place that drifts.
internal actor DatabaseAccessBridge {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseAccess")

    internal init() {}

    // MARK: - Connect

    internal struct ConnectionSnapshot: Sendable {
        internal let serverVersion: String?
        internal let database: String
        internal let schema: String?
    }

    internal struct ConnectionStatusSnapshot: Sendable {
        internal let status: ConnectionStatus
        internal let database: String
        internal let schema: String?
        internal let serverVersion: String?
        internal let connectedAt: Date
        internal let lastActiveAt: Date
    }

    internal func connect(connectionId: UUID) async throws -> ConnectionSnapshot {
        let connection = try await resolveConnection(connectionId)

        let alreadyLive = await MainActor.run {
            DatabaseManager.shared.activeSessions[connectionId]?.driver != nil
        }
        if !alreadyLive {
            try await DatabaseManager.shared.ensureConnected(connection)
        }

        let snapshot = await MainActor.run { () -> ConnectionSnapshot? in
            guard let session = DatabaseManager.shared.activeSessions[connectionId],
                  let driver = session.driver
            else {
                return nil
            }
            return ConnectionSnapshot(
                serverVersion: driver.serverVersion,
                database: session.resolvedBrowseDatabase,
                schema: session.browseSchema
            )
        }

        guard let snapshot else { throw DatabaseAccessError.notConnected(connectionId) }
        return snapshot
    }

    internal func disconnect(connectionId: UUID) async throws {
        let sessionExists = await MainActor.run {
            DatabaseManager.shared.activeSessions[connectionId] != nil
        }
        guard sessionExists else { throw DatabaseAccessError.notConnected(connectionId) }
        await DatabaseManager.shared.disconnectSession(connectionId)
    }

    internal func connectionStatus(connectionId: UUID) async throws -> ConnectionStatusSnapshot {
        let snapshot = await MainActor.run { () -> ConnectionStatusSnapshot? in
            guard let session = DatabaseManager.shared.activeSessions[connectionId] else { return nil }
            return ConnectionStatusSnapshot(
                status: session.reportedStatus,
                database: session.resolvedBrowseDatabase,
                schema: session.browseSchema,
                serverVersion: session.driver?.serverVersion,
                connectedAt: session.connectedAt,
                lastActiveAt: session.lastActiveAt
            )
        }
        guard let snapshot else { throw DatabaseAccessError.notConnected(connectionId) }
        return snapshot
    }

    // MARK: - Resolve

    internal func resolveConnection(_ connectionId: UUID) async throws -> DatabaseConnection {
        try await MainActor.run {
            let connections = ConnectionStorage.shared.loadConnections()
            guard let connection = connections.first(where: { $0.id == connectionId }) else {
                throw DatabaseAccessError.notFound(
                    String(localized: "No saved connection has that id.")
                )
            }
            return connection
        }
    }

    internal func resolveDriver(_ connectionId: UUID) async throws -> (DatabaseDriver, DatabaseType) {
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
                throw DatabaseAccessError.notConnected(connectionId)
            }
        }
    }

    @discardableResult
    internal func ensureConnected(_ connectionId: UUID) async throws -> DatabaseType {
        let (_, databaseType) = try await resolveDriver(connectionId)
        return databaseType
    }

    internal func resolveScope(connectionId: UUID, database: String?, schema: String?) async throws -> DatabaseScope {
        try await ensureConnected(connectionId)
        return try await MainActor.run {
            guard let scope = DatabaseManager.shared.resolvedScope(
                database: database,
                schema: schema,
                for: connectionId
            ) else {
                throw DatabaseAccessError.invalidArgument(
                    String(localized: "No database to run against. Pass a database name.")
                )
            }
            return scope
        }
    }

    internal func switchDatabase(connectionId: UUID, database: String) async throws {
        try await DatabaseManager.shared.switchDatabase(to: database, for: connectionId)
    }

    internal func switchSchema(connectionId: UUID, schema: String) async throws {
        try await DatabaseManager.shared.switchSchema(to: schema, for: connectionId)
    }

    // MARK: - Run

    internal struct StatementOutcome: Sendable {
        internal let result: QueryResult
        internal let executionTimeMs: Double
    }

    internal func runStatement(
        scope: DatabaseScope,
        query: String,
        maxRows: Int,
        timeoutSeconds: Int,
        cancellation: (any StatementCancellationSignal)?
    ) async throws -> StatementOutcome {
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
            await cancellation.onCancelRequested {
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
                throw DatabaseAccessError.timeout(
                    String(
                        format: String(localized: "Query timed out after %d seconds"),
                        timeoutSeconds
                    )
                )
            }
            guard let first = try await group.next() else {
                throw DatabaseAccessError.dataSourceError("No result from query execution")
            }
            group.cancelAll()
            return first
        }

        return StatementOutcome(result: result, executionTimeMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1_000)
    }

    internal static func stripTrailingSemicolons(_ query: String) -> String {
        var result = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(";") {
            result = String(result.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

/// What a transport offers a running statement so its own cancellation reaches the driver.
///
/// MCP has `notifications/cancelled` and passes its token; AppleScript has no such notification and
/// passes nil, which is why this is optional rather than a required argument.
internal protocol StatementCancellationSignal: Sendable {
    func onCancelRequested(_ handler: @escaping @Sendable () async -> Void) async
}
