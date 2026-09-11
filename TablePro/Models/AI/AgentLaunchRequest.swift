//
//  AgentLaunchRequest.swift
//  TablePro
//

import Foundation

/// A request to land in Assistant mode on one connection, from outside any window.
///
/// `sessionId` is set when a listed session is reopened and nil when a new one is started, which is
/// the only difference between the two welcome-window actions.
internal struct AgentLaunchRequest: Equatable, Sendable {
    internal let connectionId: UUID
    internal let prompt: String?
    internal let sessionId: UUID?

    internal init(connectionId: UUID, prompt: String? = nil, sessionId: UUID? = nil) {
        self.connectionId = connectionId
        self.prompt = prompt
        self.sessionId = sessionId
    }
}

/// What a launch request does about a window.
internal enum AgentLaunchRoute: Equatable, Sendable {
    /// A window already hosts the connection: bring it forward and repaint it in Assistant mode.
    /// Opening a second one would give the connection two hosts, which the workspace registry and
    /// the per-connection content-mode store both assume cannot happen.
    case focusExistingWindow(connectionId: UUID, sessionId: UUID?)
    /// No window hosts it: open one, connecting on the way. A stopped session reaches here too, which
    /// is what makes reopening one reconnect.
    case openWindow(connectionId: UUID, sessionId: UUID?)
}

/// Pure, so the decision is testable without a window server.
internal enum AgentLaunchRouter {
    internal static func route(
        _ request: AgentLaunchRequest,
        hostedConnectionIds: Set<UUID>
    ) -> AgentLaunchRoute {
        hostedConnectionIds.contains(request.connectionId)
            ? .focusExistingWindow(connectionId: request.connectionId, sessionId: request.sessionId)
            : .openWindow(connectionId: request.connectionId, sessionId: request.sessionId)
    }
}
