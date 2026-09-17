//
//  ChatToolTarget.swift
//  TablePro
//

import Foundation

internal enum ChatToolTargetError: LocalizedError, Equatable {
    case outsideSession
    case noConnection

    internal var errorDescription: String? {
        switch self {
        case .outsideSession:
            return String(localized: """
                This conversation works on one connection, and that is the only one it can reach. \
                Open the other connection and ask there.
                """)
        case .noConnection:
            return String(localized: "Attach a connection to this conversation first.")
        }
    }
}

/// The one place a chat tool learns which connection it acts on, and the only place that answer is
/// authorized.
///
/// Two functions used to answer "which connection is this call about" and nothing made them agree.
/// The approval state was computed from the view model's own connection while every tool read
/// `connection_id` out of the model's input in preference to it, so a call approved against a
/// connection sitting at Silent executed against a different one and skipped that connection's
/// Safe Mode. Six of the nine tools reached `MCPConnectionBridge` without consulting `MCPAuthPolicy`
/// at all, which made the schema and DDL of every saved connection readable by id with no approval
/// card, including connections whose AI access is off.
///
/// Resolution and authorization happen together here so the two answers cannot drift apart again,
/// and `ChatToolContext` deliberately exposes no resolver of its own.
internal enum ChatToolTarget {
    /// The connection this call acts on.
    ///
    /// The session's connection is authoritative. The in-app tools no longer publish a
    /// `connection_id` parameter, so a model naming one is either confused or following an older
    /// convention; either way it is refused rather than honoured. A conversation with no connection
    /// attached has nothing to act on.
    internal static func resolve(context: ChatToolContext, input: JsonValue) throws -> UUID {
        guard let sessionConnectionId = context.connectionId else {
            throw ChatToolTargetError.noConnection
        }
        if let named = try? ChatToolArgumentDecoder.requireUUID(input, key: "connection_id"),
           named != sessionConnectionId {
            throw ChatToolTargetError.outsideSession
        }
        return sessionConnectionId
    }

    /// The connection this call acts on, once the assistant is allowed to touch it.
    ///
    /// Authorized against **AI Policy**, deliberately not against the External Clients level. The
    /// connection form states the separation: AI Policy governs the in-app assistant, and External
    /// Clients governs Raycast, Cursor, Claude Desktop, other MCP clients and AppleScript. Routing
    /// the assistant through `MCPAuthPolicy.authorize` would apply the external gate to it, and
    /// `externalAccess` defaults to `.readOnly` on every connection, so the assistant would have
    /// stopped being able to write at all.
    ///
    /// Safe Mode is not consulted here. It is the execution gate's question, asked per statement
    /// with the statement in hand, and asking it twice in two places is how the two answers drift.
    internal static func authorized(
        context: ChatToolContext,
        input: JsonValue,
        tool: MCPToolName,
        sql: String? = nil
    ) async throws -> UUID {
        let connectionId = try resolve(context: context, input: input)
        guard let policy = await context.aiPolicy(for: connectionId) else {
            throw ChatToolAuthorizationError.denied(String(localized: "Connection not found"))
        }
        guard policy != .never else {
            throw ChatToolAuthorizationError.denied(
                String(localized: "AI access is turned off for this connection.")
            )
        }
        return connectionId
    }
}

internal enum ChatToolAuthorizationError: LocalizedError, Equatable {
    case denied(String)

    internal var errorDescription: String? {
        switch self {
        case .denied(let reason):
            return reason
        }
    }
}
