//
//  MainSplitViewController+AgentSessions.swift
//  TablePro
//

import AppKit

/// How a session command puts its question: a sheet on the window it came from in the app, and an
/// answer without one under test, where a modal alert would hold the whole run.
internal typealias AgentSessionConfirming = @MainActor (AgentSessionConfirmation, NSWindow?) async -> Bool

/// Agent mode's four session commands, and the one place each of them is carried out.
///
/// The rail's buttons and its context menu end here, and the menu bar's own items will, so a command
/// behaves the same whichever of them asked. A menu item names its session in `representedObject`,
/// which is how a menu listing a connection's sessions will reach one; anything else acts on the
/// session highlighted in the rail, the way a list command acts on the list's selection.
///
/// Every command ends in `applyContentMode(for:)`. Close used to go from the rail straight to the
/// registry, which stopped the session and told no pane, so the conversation column went on drawing
/// it with a composer that still took messages.
internal extension MainSplitViewController {
    @objc func newAgentSession(_ sender: Any?) {
        guard let connectionId = workspaces.selectedConnectionId else { return }
        startAgentSession(for: connectionId)
    }

    @objc func openAgentSession(_ sender: Any?) {
        guard let session = agentSessionTarget(for: sender) else { return }
        openAgentSession(id: session.id, connectionId: session.connectionId)
    }

    @objc func closeAgentSession(_ sender: Any?) {
        guard let session = agentSessionTarget(for: sender) else { return }
        Task { await requestCloseAgentSession(id: session.id, connectionId: session.connectionId) }
    }

    @objc func deleteAgentSession(_ sender: Any?) {
        guard let session = agentSessionTarget(for: sender) else { return }
        Task { await requestDeleteAgentSession(id: session.id, connectionId: session.connectionId) }
    }

    /// The sessions a menu lists: the ones the connection on screen owns, the one that last went to
    /// work first, which is the order the rail lists them in.
    ///
    /// Listed in both modes on purpose. The sessions exist either way, and a list that reported
    /// nothing over five live ones would be describing the mode rather than the connection. What
    /// browsing takes away is the ability to act on one, and `isAgentSessionCommandEnabled` says so
    /// by dimming every entry.
    var listedAgentSessions: [AgentSession] {
        guard let workspace = workspaces.selected else { return [] }
        return workspace.agentSessions.sessions(for: workspace.connectionId)
    }

    /// The session this window is drawing, which a menu ticks. Nil while browsing, where the window
    /// draws none, so nothing in the list claims to be open.
    var displayedAgentSessionId: UUID? {
        workspaces.selected?.displayedAgentSession?.id
    }

    /// The session a command acts on: the one its menu item names, or the one highlighted in the rail
    /// of the connection on screen. Nil outside Agent mode, where no rail is showing to act on, and
    /// for a session that belongs to another connection.
    func agentSessionTarget(for sender: Any?) -> AgentSession? {
        guard let workspace = workspaces.selected, workspace.resolvedContentMode == .agent else { return nil }
        let named = (sender as? NSMenuItem)?.representedObject as? UUID
        guard let sessionId = named ?? workspace.agentRail.highlightedSessionId,
              let session = workspace.agentSessions.session(id: sessionId),
              session.connectionId == workspace.connectionId else { return nil }
        return session
    }

    func startAgentSession(for connectionId: UUID) {
        guard let workspace = workspaces.workspace(for: connectionId) else { return }
        workspace.agentSessions.startSession(for: connectionId)
        applyContentMode(for: workspace)
    }

    func openAgentSession(id sessionId: UUID, connectionId: UUID) {
        guard let workspace = workspaces.workspace(for: connectionId),
              let session = workspace.agentSessions.session(id: sessionId) else { return }
        session.resume()
        workspace.agentSessions.setDisplayedSession(sessionId, for: connectionId)
        applyContentMode(for: workspace)
    }

    /// Asks only when the session is busy, since stopping one that is not loses nothing.
    func requestCloseAgentSession(id sessionId: UUID, connectionId: UUID) async {
        guard let session = workspaces.workspace(for: connectionId)?.agentSessions.session(id: sessionId),
              !session.status.isEnded else { return }
        if let confirmation = AgentSessionConfirmation.close(session.displayTitle, status: session.status) {
            guard await confirmAgentSessionCommand(confirmation, view.window) else { return }
        }
        guard let workspace = workspaces.workspace(for: connectionId) else { return }
        workspace.agentSessions.stopSession(id: sessionId)
        repaintEveryWindow(hosting: connectionId)
    }

    func requestDeleteAgentSession(id sessionId: UUID, connectionId: UUID) async {
        guard let session = workspaces.workspace(for: connectionId)?.agentSessions.session(id: sessionId) else {
            return
        }
        let confirmation = AgentSessionConfirmation.delete(session.displayTitle, status: session.status)
        guard await confirmAgentSessionCommand(confirmation, view.window),
              let workspace = workspaces.workspace(for: connectionId) else { return }
        workspace.agentSessions.removeSession(id: sessionId)
        repaintEveryWindow(hosting: connectionId)
    }

    /// Closing or deleting a session is the one pair of commands whose result another window cannot
    /// discover for itself.
    ///
    /// The registry can now hand the displayed session over to nothing, which is a value nothing
    /// could reach while `removeSession` had no caller outside a test, and a second window's
    /// trailing assistant resolves its session once and then observes only that session. Repainting
    /// the commanding window alone left that assistant pointed at a session that had gone, and
    /// blank until the user switched surface. This is the pane rule in its own words: a workspace is
    /// repainted for the phase it ends in, every workspace's, not just the one on screen.
    ///
    /// This window first and unconditionally, because it is the one the command came from and it is
    /// hosted whether or not anything has registered it.
    private func repaintEveryWindow(hosting connectionId: UUID) {
        repaintAgentRail(hosting: connectionId, in: self)
        for host in WindowManager.shared.hostControllers(for: connectionId) where host !== self {
            repaintAgentRail(hosting: connectionId, in: host)
        }
    }

    private func repaintAgentRail(hosting connectionId: UUID, in host: MainSplitViewController) {
        guard let workspace = host.workspaces.workspace(for: connectionId) else { return }
        if let highlighted = workspace.agentRail.highlightedSessionId,
           workspace.agentSessions.session(id: highlighted) == nil {
            workspace.agentRail.highlightedSessionId = workspace.displayedAgentSession?.id
        }
        host.applyContentMode(for: workspace)
    }

    /// A sheet on the window the command came from. Only deleting uses the destructive shape, which
    /// takes Return off the confirming button; closing a busy session is a step the person asked for.
    static func presentAgentSessionConfirmation(
        _ confirmation: AgentSessionConfirmation,
        in window: NSWindow?
    ) async -> Bool {
        if confirmation.isDestructive {
            return await AlertHelper.confirmDestructive(
                title: confirmation.title,
                message: confirmation.message,
                confirmButton: confirmation.confirmButton,
                window: window
            )
        }
        return await AlertHelper.confirm(
            title: confirmation.title,
            message: confirmation.message,
            confirmButton: confirmation.confirmButton,
            window: window
        )
    }
}
