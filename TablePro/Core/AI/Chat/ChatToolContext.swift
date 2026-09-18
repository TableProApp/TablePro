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

    init(
        connectionId: UUID?,
        bridge: MCPConnectionBridge,
        authPolicy: MCPAuthPolicy,
        sessionId: UUID? = nil,
        approvalWasExplicit: Bool = false
    ) {
        self.connectionId = connectionId
        self.bridge = bridge
        self.authPolicy = authPolicy
        self.sessionId = sessionId
        self.approvalWasExplicit = approvalWasExplicit
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
            approvalWasExplicit: approvalWasExplicit
        )
    }

    /// This connection's AI Policy, or nil when no such connection is saved.
    ///
    /// Read live rather than from a held record: the view model's copy is refreshed only when the
    /// connection's id changes, so a policy set while the pane stayed mounted would not be seen.
    func aiPolicy(for connectionId: UUID) async -> AIConnectionPolicy? {
        await MainActor.run {
            let resolved: DatabaseConnection?
            switch DatabaseManager.shared.connectionState(connectionId) {
            case .live(_, let session): resolved = session.connection
            case .stored(let connection): resolved = connection
            case .unknown: resolved = nil
            }
            guard let resolved else { return nil }
            return resolved.aiPolicy ?? AppSettingsManager.shared.ai.defaultConnectionPolicy
        }
    }

    /// The write capabilities this call may claim, which is where approval provenance is spent.
    var writeCapabilities: CallerCapabilities {
        approvalWasExplicit
            ? [.mayWrite, .mayRunDestructive, .confirmationPreCleared]
            : [.mayWrite, .mayRunDestructive]
    }
}
