//
//  ToolbarContext.swift
//  TablePro
//

import Foundation

/// Everything the connection window's toolbar is allowed to know about what the window is showing.
///
/// The toolbar used to carry one tab-shaped fact, `isTableTab`, and no content mode at all, so a
/// single list of identifiers was vended for every tab kind, every pane and both content modes and
/// the only lever anyone had was dimming. Every feature that arrived then had to buy a permanent
/// slot in the titlebar.
///
/// Nothing global is read inside this struct or inside the resolvers that take it. It is built once
/// per change by the toolbar and passed down, so the resolvers stay pure and testable with no host
/// app and no session.
internal struct ToolbarContext: Equatable {
    /// What the window's detail pane is drawing. `nil` when no tab is selected, which is a real
    /// state on a window that has just opened.
    internal let tabKind: TabType?
    internal let resultsMode: ResultsViewMode?
    internal let contentMode: ConnectionWorkspaceContentMode
    internal let pane: ConnectionWindowPane

    /// True whenever the session is alive, which includes a query in flight. A running query is not
    /// a reason to disable Refresh, and the menu bar derives its own answer from the window phase
    /// rather than from execution.
    internal let isConnected: Bool
    /// A connection is on screen, whether or not it has finished connecting.
    internal let hasSelectedWorkspace: Bool
    internal let isTrailingPaneOpen: Bool
    internal let canToggleTrailingPane: Bool

    internal let pendingChange: PendingChangeKind?
    /// Not a projection of `pendingChange`. The two are computed from different inputs: a dirty
    /// query file raises the commit control and leaves this false, which is exactly the distinction
    /// Preview SQL is gated on.
    internal let hasDataPendingChanges: Bool
    internal let blocksAllWrites: Bool

    internal let canAddRow: Bool
    internal let canRestorePreviousValues: Bool
    internal let canNavigateBack: Bool
    internal let canNavigateForward: Bool

    internal let isFileBased: Bool
    internal let supportsContainerSwitching: Bool
    internal let supportsImport: Bool
    internal let supportsServerDashboard: Bool

    internal let isAIEnabled: Bool
    internal let hasAgentSession: Bool

    /// What this engine calls the thing the centre's second capsule names, and what it calls its
    /// query language. Both are words the Actions menu puts in front of the user.
    internal let containerEntityName: String
    internal let queryLanguageName: String

    /// The subset of the context that may move an item in or out of the titlebar.
    ///
    /// This is the whole anti-reflow rule in one type. `isHidden` is written only from these
    /// fields, so the item set can change on a tab switch, a mode switch or a connection switch and
    /// on nothing else; everything transient rides `isEnabled` instead. A keystroke in a cell
    /// editor therefore costs one struct comparison and writes nothing.
    internal struct VisibilityKey: Equatable {
        internal let tabKind: TabType?
        internal let resultsMode: ResultsViewMode?
        internal let contentMode: ConnectionWorkspaceContentMode
        internal let isFileBased: Bool
        internal let supportsContainerSwitching: Bool
        internal let supportsImport: Bool
        internal let supportsServerDashboard: Bool
        internal let isAIEnabled: Bool
    }

    internal var visibilityKey: VisibilityKey {
        VisibilityKey(
            tabKind: tabKind,
            resultsMode: resultsMode,
            contentMode: contentMode,
            isFileBased: isFileBased,
            supportsContainerSwitching: supportsContainerSwitching,
            supportsImport: supportsImport,
            supportsServerDashboard: supportsServerDashboard,
            isAIEnabled: isAIEnabled
        )
    }

    internal init(
        tabKind: TabType? = nil,
        resultsMode: ResultsViewMode? = nil,
        contentMode: ConnectionWorkspaceContentMode = .browse,
        pane: ConnectionWindowPane = .empty,
        isConnected: Bool = false,
        hasSelectedWorkspace: Bool = false,
        isTrailingPaneOpen: Bool = false,
        canToggleTrailingPane: Bool = false,
        pendingChange: PendingChangeKind? = nil,
        hasDataPendingChanges: Bool = false,
        blocksAllWrites: Bool = false,
        canAddRow: Bool = false,
        canRestorePreviousValues: Bool = false,
        canNavigateBack: Bool = false,
        canNavigateForward: Bool = false,
        isFileBased: Bool = false,
        supportsContainerSwitching: Bool = false,
        supportsImport: Bool = false,
        supportsServerDashboard: Bool = false,
        isAIEnabled: Bool = false,
        hasAgentSession: Bool = false,
        containerEntityName: String = "",
        queryLanguageName: String = ""
    ) {
        self.tabKind = tabKind
        self.resultsMode = resultsMode
        self.contentMode = contentMode
        self.pane = pane
        self.isConnected = isConnected
        self.hasSelectedWorkspace = hasSelectedWorkspace
        self.isTrailingPaneOpen = isTrailingPaneOpen
        self.canToggleTrailingPane = canToggleTrailingPane
        self.pendingChange = pendingChange
        self.hasDataPendingChanges = hasDataPendingChanges
        self.blocksAllWrites = blocksAllWrites
        self.canAddRow = canAddRow
        self.canRestorePreviousValues = canRestorePreviousValues
        self.canNavigateBack = canNavigateBack
        self.canNavigateForward = canNavigateForward
        self.isFileBased = isFileBased
        self.supportsContainerSwitching = supportsContainerSwitching
        self.supportsImport = supportsImport
        self.supportsServerDashboard = supportsServerDashboard
        self.isAIEnabled = isAIEnabled
        self.hasAgentSession = hasAgentSession
        self.containerEntityName = containerEntityName
        self.queryLanguageName = queryLanguageName
    }
}
