//
//  ChatToolContext.swift
//  TablePro
//

import Foundation

/// Per-call context passed to `ChatTool.execute(input:context:)`. Carries the session's connection,
/// the shared `MCPConnectionBridge` actor that does the underlying database work, and the
/// `MCPAuthPolicy` that authorizes the call and gates writes through the connection's safe-mode
/// dialog.
///
/// `connectionId` is the session's own connection and is the only connection a tool may act on. A
/// tool never reads `connection_id` out of the model's input: that is what let an approval computed
/// against one connection authorize a statement executed against another. `ChatToolTarget` is the
/// one door, and it is why this type no longer carries a resolver of its own.
struct ChatToolContext: Sendable {
    typealias PolicyLookup = @Sendable (UUID) async -> AIConnectionPolicy?

    let connectionId: UUID?
    let bridge: MCPConnectionBridge
    let authPolicy: MCPAuthPolicy

    /// The agent session this call belongs to. Only the audit entry for an outside MCP server reads
    /// it, and it reads it because "which conversation sent this" is the first question asked of a
    /// call that left the machine.
    let sessionId: UUID?

    /// Whether the user answered this call's own approval card with Run or Always.
    ///
    /// Only an explicit answer pre-clears the execution gate's confirmation, because only then has
    /// the user been shown this statement and this connection. A grant carried over from
    /// `aiAlwaysAllowedTools` is consent for the tool, not for the statement, so the gate still asks
    /// and still shows the SQL. Every chat tool used to pass `.confirmationPreCleared`
    /// unconditionally, which skipped the only screen naming what was about to run and where.
    let approvalWasExplicit: Bool

    private let policyLookup: PolicyLookup

    init(
        connectionId: UUID?,
        bridge: MCPConnectionBridge,
        authPolicy: MCPAuthPolicy,
        sessionId: UUID? = nil,
        approvalWasExplicit: Bool = false,
        policyLookup: @escaping PolicyLookup = ChatToolContext.savedPolicy
    ) {
        self.connectionId = connectionId
        self.bridge = bridge
        self.authPolicy = authPolicy
        self.sessionId = sessionId
        self.approvalWasExplicit = approvalWasExplicit
        self.policyLookup = policyLookup
    }

    /// The same context bound to one block's approval outcome.
    ///
    /// One context is built per streaming round and shared by every block in it, including blocks
    /// that run concurrently, so provenance cannot live on the shared value.
    func carrying(approvalWasExplicit: Bool) -> ChatToolContext {
        ChatToolContext(
            connectionId: connectionId,
            bridge: bridge,
            authPolicy: authPolicy,
            sessionId: sessionId,
            approvalWasExplicit: approvalWasExplicit,
            policyLookup: policyLookup
        )
    }

    /// This connection's AI Policy, or nil when there is no such connection.
    func aiPolicy(for connectionId: UUID) async -> AIConnectionPolicy? {
        await policyLookup(connectionId)
    }

    static let savedPolicy: PolicyLookup = { connectionId in
        await MainActor.run {
            AIConnectionAccessGate.policy(
                for: connectionId,
                connectionStorage: .shared,
                databaseManager: .shared,
                defaultPolicy: AppSettingsManager.shared.ai.defaultConnectionPolicy
            )
        }
    }

    /// The write capabilities this call may claim, which is where approval provenance is spent.
    var writeCapabilities: CallerCapabilities {
        approvalWasExplicit
            ? [.mayWrite, .mayRunDestructive, .confirmationPreCleared]
            : [.mayWrite, .mayRunDestructive]
    }
}
