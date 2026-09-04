//
//  ChatToolScope.swift
//  TablePro
//

import Foundation

/// Who is asking for a tool, and on what.
///
/// Resolution used to take a chat mode and nothing else, which is the only question a single flat
/// registry can answer. That shape cannot express a per-connection allowlist at all, which is what
/// an outside MCP server needs before its tools may be offered to a session.
///
/// Built-in tools ignore the session and the connection, so carrying them changes nothing today.
/// The point is that the question is now askable.
internal struct ChatToolScope: Hashable, Sendable {
    internal let sessionId: UUID
    internal let connectionId: UUID?
    internal let mode: AIChatMode
}
