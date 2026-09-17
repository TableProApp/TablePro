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

    /// The connection this call acts on, once `MCPAuthPolicy` has allowed it.
    ///
    /// `sql` is passed by the two write tools so the policy's write-scope and write-intent arms bind
    /// to the statement rather than to the tool name alone.
    internal static func authorized(
        context: ChatToolContext,
        input: JsonValue,
        tool: MCPToolName,
        sql: String? = nil
    ) async throws -> UUID {
        let connectionId = try resolve(context: context, input: input)
        let decision = try await context.authPolicy.authorize(
            principal: .inAppAssistant,
            tool: tool,
            connectionId: connectionId,
            sql: sql
        )
        switch decision {
        case .allowed:
            return connectionId
        case .denied(let reason), .deniedInsufficientScope(_, let reason):
            throw ChatToolAuthorizationError.denied(reason)
        case .requiresUserApproval:
            /// The connection-approval ledger exists to ask before an outside MCP client reaches a
            /// connection. The assistant is not one: this is the connection whose window the user
            /// opened, which is the same consent the ledger collects, so it is not asked for twice.
            return connectionId
        }
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
