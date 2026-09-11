//
//  ChatToolContext.swift
//  TablePro
//

import Foundation

/// Per-call context passed to `ChatTool.execute(input:context:)`. Carries the
/// active chat connection (so tools can default `connection_id` arguments),
/// the shared `MCPConnectionBridge` actor that does the underlying database
/// work, and the `MCPAuthPolicy` that gates write/destructive queries through
/// the connection's safe-mode dialog.
struct ChatToolContext: Sendable {
    let connectionId: UUID?
    let bridge: MCPConnectionBridge
    let authPolicy: MCPAuthPolicy

    /// Which session is making the call. Only the outside-MCP path reads it, and it reads it because
    /// an audit entry for a call that left the machine has to name the session that made it: the
    /// registry entry for a remote tool is shared by every session whose connection allows that
    /// server, so the tool itself cannot know.
    let sessionId: UUID?

    init(
        connectionId: UUID?,
        bridge: MCPConnectionBridge,
        authPolicy: MCPAuthPolicy,
        sessionId: UUID? = nil
    ) {
        self.connectionId = connectionId
        self.bridge = bridge
        self.authPolicy = authPolicy
        self.sessionId = sessionId
    }
}
