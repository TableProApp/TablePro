//
//  AgentSessionLauncher.swift
//  TablePro
//

import AppKit
import Foundation

/// Lands a launch request in a window, and nothing else.
///
/// The connect itself goes through `TabRouter.route(.openConnection:)`, which already knows how to
/// focus an existing window, reconnect a workspace, run a pre-connect script and close the welcome
/// window. Duplicating any of that here is how the two paths would drift.
@MainActor
internal enum AgentSessionLauncher {
    /// The mode is written to the store before the window opens.
    ///
    /// `ConnectionWorkspace.init` reads `WorkspaceContentModeStore` for its initial mode, so a write
    /// afterwards would arrive too late for a workspace being created and the window would open on
    /// the object browser instead. For a window that already exists the mode is set through the
    /// controller, which repaints.
    internal static func launch(_ request: AgentLaunchRequest) {
        guard let connection = ConnectionStorage.shared.loadConnection(id: request.connectionId) else { return }

        let session = resolveSession(request, connection: connection)
        if let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            session.pendingPrompt = prompt
        }

        WorkspaceContentModeStore.shared.setMode(.assistant, connectionId: request.connectionId)

        let route = AgentLaunchRouter.route(request, hostedConnectionIds: hostedConnectionIds())
        switch route {
        case .focusExistingWindow(let connectionId, _):
            applyToHostingWindow(connectionId: connectionId, sessionId: session.id)
        case .openWindow:
            break
        }

        Task {
            do {
                try await TabRouter.shared.route(.openConnection(request.connectionId))
            } catch {
                WelcomeRouter.shared.routeError(error, for: connection)
            }
        }
    }

    /// Reopens the session the request names, or starts one. A named session that has since been
    /// closed falls back to starting a new one rather than doing nothing, because the row the user
    /// clicked was on screen a moment ago.
    private static func resolveSession(
        _ request: AgentLaunchRequest,
        connection: DatabaseConnection
    ) -> AgentSession {
        let registry = AgentSessionRegistry.shared
        if let sessionId = request.sessionId, let existing = registry.existingSession(id: sessionId) {
            return existing
        }
        return request.sessionId == nil
            ? registry.session(for: connection)
            : registry.makeSession(connection: connection)
    }

    private static func hostedConnectionIds() -> Set<UUID> {
        var hosted: Set<UUID> = []
        for window in NSApp.windows {
            guard let controller = window.contentViewController as? MainSplitViewController else { continue }
            hosted.formUnion(controller.hostedConnectionIds)
        }
        return hosted
    }

    private static func applyToHostingWindow(connectionId: UUID, sessionId: UUID) {
        for window in NSApp.windows {
            guard let controller = window.contentViewController as? MainSplitViewController,
                  controller.workspaces.contains(connectionId)
            else { continue }
            controller.selectHostedConnection(connectionId)
            controller.setContentMode(.assistant)
            controller.selectSession(id: sessionId)
            /// `setContentMode` returns without repainting when the workspace is already in
            /// assistant mode, so its flush does not run and a window already showing the assistant
            /// would keep the prompt queued. Asking again about the connection on screen is the
            /// ordinary case, not the edge one.
            if let workspace = controller.workspaces.workspace(for: connectionId) {
                controller.flushPendingPrompt(for: workspace)
            }
            return
        }
    }
}
