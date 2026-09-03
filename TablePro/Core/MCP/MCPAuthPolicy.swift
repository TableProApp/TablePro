import AppKit
import Foundation
import os

typealias MCPToolName = String

extension MCPToolName {
    static let requiresAdminScope: Set<String> = ["confirm_destructive_operation"]
    static let writeQueryTools: Set<String> = ["execute_query"]
}

enum AuthDecision: Sendable {
    case allowed
    case requiresUserApproval(reason: String)
    case denied(reason: String)
    case deniedInsufficientScope(required: Set<MCPScope>, reason: String)
}

struct MCPConnectionAuthSnapshot: Sendable {
    let policy: AIConnectionPolicy
    let externalAccess: ExternalAccessLevel
    let name: String
    let databaseType: String
}

typealias MCPConnectionSnapshotResolver = @Sendable (UUID) async -> MCPConnectionAuthSnapshot?
typealias MCPConnectionIdsProvider = @Sendable () async -> Set<UUID>

public actor MCPAuthPolicy {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPAuthPolicy")

    private let connectionResolver: MCPConnectionSnapshotResolver
    private let connectionIdsProvider: MCPConnectionIdsProvider
    private let approvalLedger: MCPApprovalLedger
    private let historyRecorder: QueryHistoryRecording
    private let approvalDedup = OnceTask<ApprovalKey, Bool>()

    public init() {
        self.init(connectionResolver: MCPAuthPolicy.defaultConnectionResolver)
    }

    init(
        connectionResolver: @escaping MCPConnectionSnapshotResolver,
        connectionIdsProvider: @escaping MCPConnectionIdsProvider = MCPAuthPolicy.defaultConnectionIdsProvider,
        approvalLedger: MCPApprovalLedger = MCPApprovalLedger(),
        historyRecorder: QueryHistoryRecording = QueryHistoryManager.shared
    ) {
        self.connectionResolver = connectionResolver
        self.connectionIdsProvider = connectionIdsProvider
        self.approvalLedger = approvalLedger
        self.historyRecorder = historyRecorder
    }

    private struct ApprovalKey: Hashable, Sendable {
        let principalKey: String
        let connectionId: UUID
    }

    func authorize(
        principal: MCPPrincipal,
        tool: MCPToolName,
        connectionId: UUID?,
        sql: String? = nil
    ) async throws -> AuthDecision {
        if let denial = Self.adminScopeDenial(principal: principal, tool: tool) {
            return denial
        }

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

        if let denial = Self.writeScopeDenial(
            principal: principal,
            tool: tool,
            sql: sql,
            databaseType: snapshot.databaseType
        ) {
            return denial
        }

        if let writeReason = denialForWriteIntent(
            tool: tool,
            sql: sql,
            externalAccess: snapshot.externalAccess,
            databaseType: snapshot.databaseType
        ) {
            return .denied(reason: writeReason)
        }

        guard snapshot.policy == .askEachTime else { return .allowed }
        let alreadyApproved = await approvalLedger.isApproved(
            principal: principal,
            connectionId: connectionId
        )
        guard !alreadyApproved else { return .allowed }

        return .requiresUserApproval(
            reason: String(
                format: String(localized: "An MCP client wants to access '%@' (%@). Allow?"),
                snapshot.name,
                snapshot.databaseType
            )
        )
    }

    /// An aggregate read spans connections, so it cannot prompt for one that asks each time. It
    /// answers the narrower question every per-connection check already asks: may this principal
    /// see this connection at all. Anything it excludes is a connection the client could not have
    /// named directly either.
    func readableConnectionIds(principal: MCPPrincipal) async -> Set<UUID> {
        let candidates = await connectionIdsProvider()
        return await readableConnectionIds(principal: principal, from: candidates)
    }

    func readableConnectionIds(principal: MCPPrincipal, from candidates: Set<UUID>) async -> Set<UUID> {
        var readable: Set<UUID> = []
        for candidate in candidates {
            guard let snapshot = await connectionResolver(candidate) else { continue }
            guard snapshot.policy != .never else { continue }
            guard snapshot.externalAccess != .blocked else { continue }
            guard principal.connectionAccess.allows(candidate) else { continue }
            readable.insert(candidate)
        }
        return readable
    }

    func resolveAndAuthorize(
        principal: MCPPrincipal,
        tool: MCPToolName,
        connectionId: UUID?,
        sql: String? = nil
    ) async throws {
        let decision = try await authorize(
            principal: principal,
            tool: tool,
            connectionId: connectionId,
            sql: sql
        )

        switch decision {
        case .allowed:
            return

        case .denied(let reason):
            throw DatabaseAccessError.forbidden(reason)

        case .deniedInsufficientScope(let required, let reason):
            throw MCPProtocolError.insufficientScope(required: required, reason: reason)

        case .requiresUserApproval(let reason):
            guard let connectionId else {
                throw DatabaseAccessError.forbidden(reason)
            }
            let approved = try await runApprovalDedup(
                principal: principal,
                connectionId: connectionId,
                reason: reason
            )
            await approvalLedger.record(
                principal: principal,
                connectionId: connectionId,
                approved: approved
            )
            guard approved else {
                throw DatabaseAccessError.forbidden(
                    String(localized: "User denied MCP access to this connection")
                )
            }
        }
    }

    func recordApproval(principal: MCPPrincipal, connectionId: UUID) async {
        await approvalLedger.record(principal: principal, connectionId: connectionId, approved: true)
    }

    func clearApprovals(tokenId: UUID?) async {
        await approvalLedger.clear(tokenId: tokenId)
    }

    func clearAllApprovals() async {
        await approvalLedger.clearAll()
    }

    /// The MCP surface never pre-clears Safe Mode on the client's word alone. `confirmationPreCleared`
    /// says a human already confirmed, and over MCP nobody did: the client typed a phrase. Only an
    /// admin-scoped token may substitute that phrase for the dialog, which is what separates Full
    /// Access from Read & Write in enforcement rather than only in the settings UI.
    func checkSafeModeDialog(
        principal: MCPPrincipal,
        sql: String,
        connectionId: UUID,
        databaseType: DatabaseType,
        capabilities: CallerCapabilities = [.mayWrite, .mayRunDestructive, .mayRunMultiStatement]
    ) async throws {
        var effective = capabilities
        if !principal.has(.admin) || principal.isAnonymous {
            effective.remove(.confirmationPreCleared)
            effective.remove(.preCleared)
        }
        try await runExecutionGate(
            sql: sql,
            connectionId: connectionId,
            databaseType: databaseType,
            capabilities: effective,
            callerLabel: principal.auditLabel
        )
    }

    func checkSafeModeDialog(
        sql: String,
        connectionId: UUID,
        databaseType: DatabaseType,
        capabilities: CallerCapabilities = [.mayWrite, .mayRunDestructive, .mayRunMultiStatement]
    ) async throws {
        try await runExecutionGate(
            sql: sql,
            connectionId: connectionId,
            databaseType: databaseType,
            capabilities: capabilities,
            callerLabel: nil
        )
    }

    private func runExecutionGate(
        sql: String,
        connectionId: UUID,
        databaseType: DatabaseType,
        capabilities: CallerCapabilities,
        callerLabel: String?
    ) async throws {
        let decision = await ExecutionGateProvider.shared.authorize(
            OperationRequest(
                connectionId: connectionId,
                databaseType: databaseType,
                sql: sql,
                kind: OperationKind.from(QueryClassifier.classifyTier(sql, databaseType: databaseType)),
                caller: .mcpClient(label: callerLabel),
                capabilities: capabilities,
                operationDescription: String(localized: "MCP query execution")
            )
        )
        if case .denied(let reason) = decision {
            throw DatabaseAccessError.forbidden(reason)
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

        let databaseType = await connectionResolver(connectionId)?.databaseType ?? ""

        await historyRecorder.record(
            QueryHistoryRecordRequest(
                query: sql,
                connectionId: connectionId,
                databaseName: databaseName,
                databaseType: DatabaseType(rawValue: databaseType),
                source: .mcp,
                executionTime: executionTime,
                rowCount: rowCount,
                wasSuccessful: wasSuccessful,
                errorMessage: errorMessage
            )
        )
    }

    private static func adminScopeDenial(principal: MCPPrincipal, tool: MCPToolName) -> AuthDecision? {
        guard MCPToolName.requiresAdminScope.contains(tool) else { return nil }
        guard !principal.has(.admin) || principal.isAnonymous else { return nil }
        return .deniedInsufficientScope(
            required: [.admin],
            reason: "Tool '\(tool)' requires an issued token carrying the admin scope"
        )
    }

    private static func writeScopeDenial(
        principal: MCPPrincipal,
        tool: MCPToolName,
        sql: String?,
        databaseType: String
    ) -> AuthDecision? {
        guard MCPToolName.writeQueryTools.contains(tool), let sql, !sql.isEmpty else { return nil }
        guard QueryClassifier.isWriteQuery(sql, databaseType: DatabaseType(rawValue: databaseType)) else {
            return nil
        }
        guard !principal.has(.toolsWrite) || principal.isAnonymous else { return nil }
        return .deniedInsufficientScope(
            required: [.toolsWrite],
            reason: "Writing requires an issued token carrying the tools:write scope"
        )
    }

    private func runApprovalDedup(
        principal: MCPPrincipal,
        connectionId: UUID,
        reason: String
    ) async throws -> Bool {
        let key = ApprovalKey(principalKey: principal.ledgerKey, connectionId: connectionId)
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
                throw DatabaseAccessError.timeout(
                    String(localized: "User approval timed out after 30 seconds")
                )
            }
            guard let result = try await group.next() else {
                throw DatabaseAccessError.dataSourceError("No result from approval prompt")
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
        if MCPToolName.requiresAdminScope.contains(tool) {
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

    static let defaultConnectionIdsProvider: MCPConnectionIdsProvider = {
        await MainActor.run {
            Set(ConnectionStorage.shared.loadConnections().map(\.id))
        }
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
