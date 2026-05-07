//
//  ChatToolContext.swift
//  TablePro
//

import Foundation

/// Per-call context passed to `ChatTool.execute(input:context:)`. Carries the
/// active chat connection (so tools can default `connection_id` arguments) and
/// the shared `MCPConnectionBridge` actor that does the underlying database work.
struct ChatToolContext: Sendable {
    let connectionId: UUID?
    let bridge: MCPConnectionBridge
}
