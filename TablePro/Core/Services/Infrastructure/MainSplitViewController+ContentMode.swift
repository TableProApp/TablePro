//
//  MainSplitViewController+ContentMode.swift
//  TablePro
//

import AppKit

/// Switching the selected connection between browsing and its agent.
///
/// The mode swaps what the window's three existing split items draw. It builds no split view of its
/// own: the sidebar, detail and trailing items already carry `sizingOptions = []`, the detail item's
/// `holdingPriority` and the trailing item's explicit macOS 13 thicknesses, and a nested split view
/// inside the detail pane would re-raise all three of the split-view bugs those exist for.
internal extension MainSplitViewController {
    /// Whether a connection is on screen, whether or not it has finished connecting.
    var hasSelectedWorkspace: Bool {
        workspaces.selected != nil
    }

    var contentMode: ConnectionWorkspaceContentMode {
        workspaces.selected?.resolvedContentMode ?? .browse
    }

    func setContentMode(_ mode: ConnectionWorkspaceContentMode) {
        guard let workspace = workspaces.selected else { return }
        setContentMode(mode, for: workspace.connectionId)
    }

    /// What Browse had collapsed, so entering Agent mode can reveal its columns and leaving can put
    /// the window back the way the user had it.
    private static var browseCollapseState: [UUID: (sidebar: Bool, inspector: Bool)] = [:]

    func setContentMode(_ mode: ConnectionWorkspaceContentMode, for connectionId: UUID) {
        guard let workspace = workspaces.workspace(for: connectionId) else { return }
        let resolved = ConnectionWorkspaceContentMode.resolved(
            mode,
            isAIEnabled: AppSettingsManager.shared.ai.enabled
        )
        guard workspace.contentMode != resolved else { return }
        workspace.contentMode = resolved

        /// Agent mode opens a session so the window has something to draw. Browsing does not stop
        /// one: leaving the mode is not the user ending a conversation, and coming back continues it.
        if resolved == .agent {
            AgentSessionRegistry.shared.resolveSession(for: connectionId, startingIfNeeded: true)
        }

        applyColumnVisibility(for: connectionId, mode: resolved)

        /// The floor follows the mode in both directions, and writes nothing to the connection: the
        /// level the user chose is handed straight back on the way out.
        AgentModeSafeModeFloor.reapply(for: connectionId)
        applyContentMode(for: workspace)
    }

    /// Agent mode needs all three of its columns.
    ///
    /// A fresh window starts with the inspector collapsed, and the user may have collapsed the
    /// sidebar, so swapping the hosted roots alone gave a first-time Agent mode with no Result
    /// column and sometimes no Sessions column either. What Browse had is remembered and put back.
    private func applyColumnVisibility(
        for connectionId: UUID,
        mode: ConnectionWorkspaceContentMode
    ) {
        guard workspaces.selectedConnectionId == connectionId else { return }
        switch mode {
        case .agent:
            Self.browseCollapseState[connectionId] = (
                sidebar: sidebarSplitItem.isCollapsed,
                inspector: inspectorSplitItem.isCollapsed
            )
            sidebarSplitItem.animator().isCollapsed = false
            inspectorSplitItem.animator().isCollapsed = false
        case .browse:
            guard let previous = Self.browseCollapseState.removeValue(forKey: connectionId) else { return }
            sidebarSplitItem.animator().isCollapsed = previous.sidebar
            inspectorSplitItem.animator().isCollapsed = previous.inspector
        }
    }

    func toggleContentMode(_ sender: Any?) {
        setContentMode(contentMode.toggled)
    }

    /// Repaints one workspace for its current mode, selected or not.
    ///
    /// A background workspace owns panes that outlive every switch, so one built for a mode it has
    /// since left stays wrong until something builds it again. That is the same reason
    /// `transition(to:for:)` ends in a sync rather than repainting only what is on screen.
    func applyContentMode(for workspace: ConnectionWorkspace) {
        syncPanes(of: workspace)
        guard workspaces.selectedConnectionId == workspace.connectionId else { return }
        showSelectedTrailingPane()
        applyPaneChrome()
        applyWindowTitle()
        toolbarOwner?.refreshContentMode()
    }

    func startAgentSession(for connectionId: UUID) {
        AgentSessionRegistry.shared.startSession(for: connectionId)
        guard let workspace = workspaces.workspace(for: connectionId) else { return }
        applyContentMode(for: workspace)
    }

    func selectAgentSession(_ sessionId: UUID, for connectionId: UUID) {
        guard let session = AgentSessionRegistry.shared.session(id: sessionId) else { return }
        session.resume()
        AgentSessionRegistry.shared.setDisplayedSession(sessionId, for: connectionId)
        AgentSessionRegistry.shared.markActive(id: sessionId)
        guard let workspace = workspaces.workspace(for: connectionId) else { return }
        applyContentMode(for: workspace)
    }
}
