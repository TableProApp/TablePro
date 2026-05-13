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
}
