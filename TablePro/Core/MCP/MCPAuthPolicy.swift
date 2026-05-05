import AppKit
import Foundation
import os

typealias MCPToolName = String

extension MCPToolName {
    static let stateMutating: Set<String> = [
        "execute_query", "confirm_destructive_operation",
        "switch_database", "switch_schema", "export_data"
    ]
    static let requiresFullAccess: Set<String> = ["confirm_destructive_operation"]
    static let requiresReadWrite: Set<String> = ["switch_database", "switch_schema", "export_data"]
    static let writeQueryTools: Set<String> = ["execute_query"]
}

enum AuthDecision: Sendable {
    case allowed
    case requiresUserApproval(reason: String)
    case denied(reason: String)
}

public actor MCPAuthPolicy {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPAuthPolicy")

    public init() {}

    private var sessionApprovals: [String: Set<UUID>] = [:]
    private let approvalDedup = OnceTask<ApprovalKey, Bool>()

    private struct ApprovalKey: Hashable, Sendable {
        let sessionId: String
        let connectionId: UUID
    }

    private struct ConnectionSnapshot: Sendable {
        let policy: AIConnectionPolicy
        let externalAccess: ExternalAccessLevel
        let name: String
        let databaseType: String
        let safeModeLevel: SafeModeLevel
    }

    func authorize(
        token: MCPAuthToken,
        tool: MCPToolName,
        connectionId: UUID?,
        sql: String? = nil,
        sessionId: String
    ) async throws -> AuthDecision {
        guard let connectionId else {
            return decideTokenTier(token: token, tool: tool)
        }

        guard let snapshot = await loadConnection(connectionId) else {
            return .denied(reason: String(localized: "Connection not found"))
        }

        if snapshot.policy == .never {
            return .denied(reason: String(localized: "AI access is disabled for this connection"))
        }

        if snapshot.externalAccess == .blocked {
            return .denied(reason: String(localized: "External access is disabled for this connection"))
        }

        if !token.connectionAccess.allows(connectionId) {
            return .denied(reason: String(localized: "Token does not have access to this connection"))
        }

        if case .denied(let reason) = decideTokenTier(token: token, tool: tool) {
            return .denied(reason: reason)
        }

        if let writeReason = denialForWriteIntent(
            tool: tool,
            sql: sql,
            externalAccess: snapshot.externalAccess,
            databaseType: snapshot.databaseType
        ) {
            return .denied(reason: writeReason)
        }

        if snapshot.policy == .askEachTime,
           !(sessionApprovals[sessionId]?.contains(connectionId) ?? false)
        {
            return .requiresUserApproval(
                reason: String(
                    format: String(localized: "An MCP client wants to access '%@' (%@). Allow?"),
                    snapshot.name,
                    snapshot.databaseType
                )
            )
        }

        return .allowed
    }

    func resolveAndAuthorize(
        token: MCPAuthToken,
        tool: MCPToolName,
        connectionId: UUID?,
        sql: String? = nil,
        sessionId: String
    ) async throws {
        let decision = try await authorize(
            token: token,
            tool: tool,
            connectionId: connectionId,
            sql: sql,
            sessionId: sessionId
        )

        switch decision {
        case .allowed:
            return

        case .denied(let reason):
            throw MCPDataLayerError.forbidden(reason)

        case .requiresUserApproval(let reason):
            guard let connectionId else {
                throw MCPDataLayerError.forbidden(reason)
            }
            let approved = try await runApprovalDedup(
                sessionId: sessionId,
                connectionId: connectionId,
                reason: reason
            )
            if approved {
                recordApproval(sessionId: sessionId, connectionId: connectionId)
            } else {
                throw MCPDataLayerError.forbidden(
                    String(localized: "User denied MCP access to this connection")
                )
            }
        }
    }

    func recordApproval(sessionId: String, connectionId: UUID) {
        sessionApprovals[sessionId, default: []].insert(connectionId)
    }

    func clearSession(_ sessionId: String) {
        sessionApprovals.removeValue(forKey: sessionId)
    }

    func checkSafeModeDialog(
        sql: String,
        connectionId: UUID,
        databaseType: DatabaseType,
        safeModeLevel: SafeModeLevel
    ) async throws {
        let isWrite = QueryClassifier.isWriteQuery(sql, databaseType: databaseType)
        let needsDialog = safeModeLevel != .silent
            && (isWrite || safeModeLevel == .alertFull || safeModeLevel == .safeModeFull)

        let window: NSWindow? = needsDialog
            ? await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                return WindowLifecycleMonitor.shared.findWindow(for: connectionId)
                    ?? NSApp.mainWindow
            }
            : nil

        let permission = await SafeModeGuard.checkPermission(
            level: safeModeLevel,
            isWriteOperation: isWrite,
            sql: sql,
            operationDescription: String(localized: "MCP query execution"),
            window: window,
            databaseType: databaseType
        )

        if case .blocked(let reason) = permission {
            throw MCPDataLayerError.forbidden(reason)
        }
    }

    func logQuery(
        sql: String,
        connectionId: UUID,
        databaseName: String,
        executionTime: TimeInterval,
        rowCount: Int,
        wasSuccessful: Bool,
        errorMessage: String?
    ) async {
        let shouldLog = await MainActor.run {
            AppSettingsManager.shared.mcp.logQueriesInHistory
        }
        guard shouldLog else { return }

        let entry = QueryHistoryEntry(
            query: sql,
            connectionId: connectionId,
            databaseName: databaseName,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: wasSuccessful,
            errorMessage: errorMessage
        )

        _ = await QueryHistoryStorage.shared.addHistory(entry)
    }

    private func runApprovalDedup(
        sessionId: String,
        connectionId: UUID,
        reason: String
    ) async throws -> Bool {
        let key = ApprovalKey(sessionId: sessionId, connectionId: connectionId)
        return try await approvalDedup.execute(key: key) {
            try await Self.promptApproval(reason: reason)
        }
    }

    private static func promptApproval(reason: String) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                await AlertHelper.runApprovalModal(
                    title: String(localized: "MCP Access Request"),
                    message: reason,
                    confirm: String(localized: "Allow"),
                    cancel: String(localized: "Deny")
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw MCPDataLayerError.timeout(
                    String(localized: "User approval timed out after 30 seconds")
                )
            }
            guard let result = try await group.next() else {
                throw MCPDataLayerError.dataSourceError("No result from approval prompt")
            }
            return result
        }
    }

    private func decideTokenTier(token: MCPAuthToken, tool: MCPToolName) -> AuthDecision {
        let required = requiredPermission(for: tool)
        if token.permissions.satisfies(required) {
            return .allowed
        }
        return .denied(
            reason: String(
                format: String(localized: "Token '%@' with permission '%@' cannot access '%@'"),
                token.name,
                token.permissions.displayName,
                tool
            )
        )
    }

    private func requiredPermission(for tool: MCPToolName) -> TokenPermissions {
        if MCPToolName.requiresFullAccess.contains(tool) { return .fullAccess }
        if MCPToolName.requiresReadWrite.contains(tool) { return .readWrite }
        return .readOnly
    }

    private func denialForWriteIntent(
        tool: MCPToolName,
        sql: String?,
        externalAccess: ExternalAccessLevel,
        databaseType: String
    ) -> String? {
        if MCPToolName.requiresReadWrite.contains(tool) || MCPToolName.requiresFullAccess.contains(tool) {
            if externalAccess != .readWrite {
                return String(localized: "Connection is read only for external clients")
            }
            return nil
        }

        guard MCPToolName.writeQueryTools.contains(tool), let sql else {
            return nil
        }

        let dbType = DatabaseType(rawValue: databaseType)
        guard QueryClassifier.isWriteQuery(sql, databaseType: dbType) else {
            return nil
        }
        if externalAccess != .readWrite {
            return String(localized: "Connection is read only for external clients")
        }
        return nil
    }

    private func loadConnection(_ connectionId: UUID) async -> ConnectionSnapshot? {
        await MainActor.run {
            let state = DatabaseManager.shared.connectionState(connectionId)
            switch state {
            case .live(_, let session):
                let conn = session.connection
                return ConnectionSnapshot(
                    policy: conn.aiPolicy ?? AppSettingsManager.shared.ai.defaultConnectionPolicy,
                    externalAccess: conn.externalAccess,
                    name: conn.name,
                    databaseType: conn.type.rawValue,
                    safeModeLevel: conn.safeModeLevel
                )
            case .stored(let conn):
                return ConnectionSnapshot(
                    policy: conn.aiPolicy ?? AppSettingsManager.shared.ai.defaultConnectionPolicy,
                    externalAccess: conn.externalAccess,
                    name: conn.name,
                    databaseType: conn.type.rawValue,
                    safeModeLevel: conn.safeModeLevel
                )
            case .unknown:
                return nil
            }
        }
    }
}
