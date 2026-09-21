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
/// Nothing global is read inside this struct or inside the resolvers that take it. The toolbar
/// builds it once per validation pass and once per Actions menu open and passes it down, so the
/// resolvers stay pure and testable with no host app and no session.
///
/// Every field is one a resolver reads. A fact nothing reads is a fact every pass pays to look up.
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
    internal let canToggleTrailingPane: Bool
    /// The View menu's own answer, carried rather than rebuilt from `isConnected`: an assistant left
    /// open over a connection that dropped can still be closed, which a session check would dim.
    internal let canToggleAssistant: Bool

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

    /// The subset of the context that may move an item in or out of the titlebar, or change what
    /// one says.
    ///
    /// This is the whole anti-reflow rule in one type. `isHidden` and the commit control's label are
    /// written only from these fields, so the titlebar can change shape on a tab switch, a mode
    /// switch or a connection switch and on nothing else; everything transient rides `isEnabled`
    /// instead. The toolbar computes this from its eight inputs directly rather than from a whole
    /// context, so a keystroke costs the selected-tab lookup, four locked reads of the plugin
    /// metadata registry, a switch over the engine for the dashboard and one comparison, and writes
    /// nothing.
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
        canToggleTrailingPane: Bool = false,
        canToggleAssistant: Bool = false,
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
        isAIEnabled: Bool = false
    ) {
        self.tabKind = tabKind
        self.resultsMode = resultsMode
        self.contentMode = contentMode
        self.pane = pane
        self.isConnected = isConnected
        self.hasSelectedWorkspace = hasSelectedWorkspace
        self.canToggleTrailingPane = canToggleTrailingPane
        self.canToggleAssistant = canToggleAssistant
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
    }

    /// The whole context over a key the caller already computed, so the eight slow-moving facts
    /// are read once per context rather than once for the key and again for the context.
    internal init(
        key: VisibilityKey,
        pane: ConnectionWindowPane,
        isConnected: Bool,
        hasSelectedWorkspace: Bool,
        canToggleTrailingPane: Bool,
        canToggleAssistant: Bool,
        pendingChange: PendingChangeKind?,
        hasDataPendingChanges: Bool,
        blocksAllWrites: Bool,
        canAddRow: Bool,
        canRestorePreviousValues: Bool,
        canNavigateBack: Bool,
        canNavigateForward: Bool
    ) {
        self.init(
            tabKind: key.tabKind,
            resultsMode: key.resultsMode,
            contentMode: key.contentMode,
            pane: pane,
            isConnected: isConnected,
            hasSelectedWorkspace: hasSelectedWorkspace,
            canToggleTrailingPane: canToggleTrailingPane,
            canToggleAssistant: canToggleAssistant,
            pendingChange: pendingChange,
            hasDataPendingChanges: hasDataPendingChanges,
            blocksAllWrites: blocksAllWrites,
            canAddRow: canAddRow,
            canRestorePreviousValues: canRestorePreviousValues,
            canNavigateBack: canNavigateBack,
            canNavigateForward: canNavigateForward,
            isFileBased: key.isFileBased,
            supportsContainerSwitching: key.supportsContainerSwitching,
            supportsImport: key.supportsImport,
            supportsServerDashboard: key.supportsServerDashboard,
            isAIEnabled: key.isAIEnabled
        )
    }
}
