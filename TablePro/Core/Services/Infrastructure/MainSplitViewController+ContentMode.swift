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
///
/// What it swaps is which of the workspace's hosting controllers each item parents, never what one
/// of them draws. That is what lets a toggle keep the browse content's grid scroll, cell selection,
/// find panel, undo stack and unsaved Create Table definition, and it is why a reparented view sees
/// `onDisappear` then `onAppear` on the same identity: everything a view releases on the first has
/// to come back on the second.
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
            workspace.agentSessions.resolveSession(for: connectionId, startingIfNeeded: true)
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
    /// column and sometimes no Sessions column either. What Browse had is remembered on the
    /// workspace and put back.
    ///
    /// Returns without touching the window when the workspace is not the one on screen, which is
    /// why `applySelectedWorkspace` calls it again: a connection put into Agent mode while another
    /// was selected reached the window with its columns still collapsed and nothing to reveal them.
    func applyColumnVisibility(
        for connectionId: UUID,
        mode: ConnectionWorkspaceContentMode
    ) {
        guard workspaces.selectedConnectionId == connectionId,
              let workspace = workspaces.workspace(for: connectionId) else { return }
        switch mode {
        case .agent:
            /// Recorded once per entry into the mode. Recording again on a later selection would
            /// save the mode's own revealed columns as the layout to go back to.
            if workspace.browseCollapseState == nil {
                workspace.browseCollapseState = (
                    sidebar: sidebarSplitItem.isCollapsed,
                    inspector: inspectorSplitItem.isCollapsed
                )
            }
            sidebarSplitItem.animator().isCollapsed = false
            inspectorSplitItem.animator().isCollapsed = false
        case .browse:
            guard let previous = workspace.browseCollapseState else { return }
            workspace.browseCollapseState = nil
            sidebarSplitItem.animator().isCollapsed = previous.sidebar
            inspectorSplitItem.animator().isCollapsed = previous.inspector
        }
    }

    func toggleContentMode(_ sender: Any?) {
        setContentMode(contentMode.toggled)
    }

    /// Repaints one workspace for its current mode, selected or not, and parents it only if it is
    /// the one on screen.
    ///
    /// A background workspace owns panes that outlive every switch, so one built for a mode it has
    /// since left stays wrong until something builds it again. That is the same reason
    /// `transition(to:for:)` ends in a sync rather than repainting only what is on screen. Parenting
    /// is the other half, and a background workspace gets it from `applySelectedWorkspace` when it
    /// is selected.
    ///
    /// The tab strip, the detail column's minimum and the title each describe the tree in the detail
    /// column, so all three follow the swap rather than whichever tab is selected behind it.
    func applyContentMode(for workspace: ConnectionWorkspace) {
        syncPanes(of: workspace)
        syncFrontmostTabManager()
        guard workspaces.selectedConnectionId == workspace.connectionId else { return }
        showSelectedContentPanes()
        showSelectedTrailingPane()
        applyDetailMinimumThicknessForSelection()
        applyPaneChrome()
        applyWindowTitle()
        toolbarOwner?.refreshContext()
    }
}
