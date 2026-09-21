//
//  MainSplitViewController+AgentPanes.swift
//  TablePro
//

import Combine
import SwiftUI

/// Agent mode's three panes, built into hosting controllers of their own beside the browse panes.
///
/// They are written only while the connection is in the mode. A connection that never enters it
/// never builds a rail or a conversation, and one that leaves keeps the rail, the conversation and
/// the result as they were, detached, so coming back is a reparent rather than a rebuild: the
/// result keeps the run it was showing, its segment and its sort. The transcript does not keep
/// its scroll position. `AIChatPanelView` scrolls to the latest message whenever it appears, which
/// a reparent is, and that is also where a session that went on working while the user browsed
/// has got to.
internal extension MainSplitViewController {
    func refreshAgentPanes(of workspace: ConnectionWorkspace) {
        guard workspace.resolvedContentMode == .agent else { return }
        workspace.panes.agentRail.rootView = AnyView(buildAgentRailView(for: workspace))
        workspace.panes.agentConversation.rootView = AnyView(buildAgentConversationView(for: workspace))
        workspace.panes.agentResult.rootView = AnyView(buildAgentResultView(for: workspace))
    }

    /// Re-arms only when the session naming the window changes, so the title can be asked for on
    /// every phase change and mode toggle without stacking subscriptions.
    ///
    /// `@Published` announces a change before the value is stored, so the title is read back on the
    /// next turn of the run loop rather than from inside the announcement.
    func followTitle(of session: AgentSession?) {
        guard session !== observedAgentSession else { return }
        observedAgentSession = session
        agentTitleCancellable = session?.$title
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyWindowTitle()
            }
    }

    /// Every one of the rail's commands goes back through the window rather than to the registry, so
    /// stopping or discarding the session on screen repaints the panes that were drawing it.
    @ViewBuilder
    private func buildAgentRailView(for workspace: ConnectionWorkspace) -> some View {
        if let connection = workspace.connection {
            AgentSessionRailView(
                connectionId: connection.id,
                registry: workspace.agentSessions,
                railState: workspace.agentRail,
                openSessionId: workspace.displayedAgentSession?.id,
                onOpen: { [weak self] sessionId in
                    self?.openAgentSession(id: sessionId, connectionId: connection.id)
                },
                onNewSession: { [weak self] in self?.startAgentSession(for: connection.id) },
                onClose: { [weak self] sessionId in
                    Task { await self?.requestCloseAgentSession(id: sessionId, connectionId: connection.id) }
                },
                onDelete: { [weak self] sessionId in
                    Task { await self?.requestDeleteAgentSession(id: sessionId, connectionId: connection.id) }
                }
            )
            .transaction { $0.animation = nil }
        } else {
            Color.clear
        }
    }

    /// Built whatever the pane, and parented only for the panes `ConnectionWindowPaneResolver.detailMode`
    /// gives it. A connection that drops while the conversation is on screen therefore keeps the
    /// conversation, detached, behind the unavailable screen, and a reconnect puts the same one back.
    ///
    /// The Safe Mode floor is read here rather than in the view, because it is the answer to a
    /// question about every window in the app: a connection is in Agent mode while any of them has it
    /// in the mode, and only `AgentModeSafeModeFloor` can ask that.
    @ViewBuilder
    private func buildAgentConversationView(for workspace: ConnectionWorkspace) -> some View {
        if let connection = workspace.connection {
            AgentConversationView(
                connection: connection,
                session: workspace.displayedAgentSession,
                isConnecting: workspace.resolvedPane == .connecting,
                safeModeFloor: AgentModeSafeModeFloor.effectiveFloor(for: connection),
                onStartSession: { [weak self] in self?.startAgentSession(for: connection.id) }
            )
            .transaction { $0.animation = nil }
        } else {
            Color.clear
        }
    }

    /// The session's statements and rows, over a live connection only.
    @ViewBuilder
    private func buildAgentResultView(for workspace: ConnectionWorkspace) -> some View {
        let session = workspace.displayedAgentSession
        if let reason = TrailingPaneUnavailableView.Reason.agentResult(
            pane: workspace.resolvedPane,
            hasSession: session != nil
        ) {
            TrailingPaneUnavailableView(
                surface: .agentResult,
                reason: reason,
                contentMode: workspace.contentMode,
                paneState: nil
            )
        } else if let session {
            AgentResultPaneView(session: session, connection: workspace.connection, contentMode: workspace.contentMode)
        }
    }
}
