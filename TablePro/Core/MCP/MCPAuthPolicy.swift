import AppKit
import Foundation
import os

typealias MCPToolName = String

extension MCPToolName {
    static let requiresFullAccess: Set<String> = ["confirm_destructive_operation"]
    static let writeQueryTools: Set<String> = ["execute_query"]
}

enum AuthDecision: Sendable {
    case allowed
    case requiresUserApproval(reason: String)
    case denied(reason: String)
}

struct MCPConnectionAuthSnapshot: Sendable {
    let policy: AIConnectionPolicy
    let externalAccess: ExternalAccessLevel
    let name: String
    let databaseType: String
}

typealias MCPConnectionSnapshotResolver = @Sendable (UUID) async -> MCPConnectionAuthSnapshot?

public actor MCPAuthPolicy {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPAuthPolicy")

    private let connectionResolver: MCPConnectionSnapshotResolver

    public init() {
        self.init(connectionResolver: MCPAuthPolicy.defaultConnectionResolver)
    }

    init(connectionResolver: @escaping MCPConnectionSnapshotResolver) {
        self.connectionResolver = connectionResolver
    }

    private var sessionApprovals: [String: Set<UUID>] = [:]
    private let approvalDedup = OnceTask<ApprovalKey, Bool>()

    private struct ApprovalKey: Hashable, Sendable {
        let sessionId: String
        let connectionId: UUID
    }

    func authorize(
        principal: MCPPrincipal,
        tool: MCPToolName,
        connectionId: UUID?,
        sql: String? = nil,
        sessionId: String
    ) async throws -> AuthDecision {
        guard let connectionId else {
            return .allowed
        }

        guard let snapshot = await connectionResolver(connectionId) else {
            return .denied(reason: String(localized: "Connection not found"))
        }

        if snapshot.policy == .never {
            return .denied(reason: String(localized: "AI access is disabled for this connection"))
        }

        if snapshot.externalAccess == .blocked {
            return .denied(reason: String(localized: "External access is disabled for this connection"))
        }

        if !principal.connectionAccess.allows(connectionId) {
            return .denied(reason: String(localized: "Token does not have access to this connection"))
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
        principal: MCPPrincipal,
        tool: MCPToolName,
        connectionId: UUID?,
        sql: String? = nil,
        sessionId: String
    ) async throws {
        let decision = try await authorize(
            principal: principal,
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
        capabilities: CallerCapabilities = [.mayWrite, .mayRunDestructive, .mayRunMultiStatement]
    ) async throws {
        let decision = await ExecutionGateProvider.shared.authorize(
            OperationRequest(
                connectionId: connectionId,
                databaseType: databaseType,
                sql: sql,
                kind: OperationKind.from(QueryClassifier.classifyTier(sql, databaseType: databaseType)),
                caller: .mcpClient(label: nil),
                capabilities: capabilities,
                operationDescription: String(localized: "MCP query execution")
            )
        )
        if case .denied(let reason) = decision {
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

        _ = await QueryHistoryManager.shared.addHistory(entry)
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

    private func denialForWriteIntent(
        tool: MCPToolName,
        sql: String?,
        externalAccess: ExternalAccessLevel,
        databaseType: String
    ) -> String? {
        if MCPToolName.requiresFullAccess.contains(tool) {
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

    private static let defaultConnectionResolver: MCPConnectionSnapshotResolver = { connectionId in
        await MainActor.run {
            switch DatabaseManager.shared.connectionState(connectionId) {
            case .live(_, let session):
                let conn = session.connection
                return MCPConnectionAuthSnapshot(
                    policy: conn.aiPolicy ?? AppSettingsManager.shared.ai.defaultConnectionPolicy,
                    externalAccess: conn.externalAccess,
                    name: conn.name,
                    databaseType: conn.type.rawValue
                )
            case .stored(let conn):
                return MCPConnectionAuthSnapshot(
                    policy: conn.aiPolicy ?? AppSettingsManager.shared.ai.defaultConnectionPolicy,
                    externalAccess: conn.externalAccess,
                    name: conn.name,
                    databaseType: conn.type.rawValue
                )
            case .unknown:
                return nil
            }
        }
    }
}
