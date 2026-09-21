//
//  MainWindowToolbar+Context.swift
//  TablePro
//

import AppKit
import TableProPluginKit

internal extension MainWindowToolbar {
    /// The window's own controller, not the connection's coordinator.
    ///
    /// A workspace that is still connecting, or disconnected, has no `MainContentCoordinator`, so
    /// reaching the split controller through one made the window's own commands inert in exactly
    /// the state a user reaches for them.
    var host: MainSplitViewController? {
        windowController ?? coordinator?.splitViewController
    }

    /// The engine the window is showing, read from the workspace's connection record and never from
    /// the coordinator.
    ///
    /// The coordinator goes with the session, so a capability read through it would take the
    /// container capsule out of the titlebar and put it back on every dropped connection, which is
    /// the titlebar moving on something transient.
    private var databaseType: DatabaseType? {
        host?.workspaces.selected?.connection?.type ?? coordinator?.connection.type
    }

    /// The eight slow-moving facts, read on their own and never through a whole context.
    ///
    /// This is what every tab-manager publish pays, and typing publishes one per keystroke, so it
    /// reads only what the key holds: the selected tab, the window's mode, four locked reads of the
    /// plugin metadata registry and a switch over the engine for the dashboard. Everything
    /// transient, and every question that walks the coordinator, is left to `currentContext()`.
    func currentVisibilityKey() -> ToolbarContext.VisibilityKey {
        let tab = coordinator?.tabManager.selectedTab
        let databaseType = self.databaseType
        return ToolbarContext.VisibilityKey(
            tabKind: tab?.tabType,
            resultsMode: tab?.display.resultsViewMode,
            contentMode: host?.contentMode ?? .browse,
            isFileBased: databaseType.map { PluginManager.shared.connectionMode(for: $0) == .fileBased } ?? false,
            supportsContainerSwitching: databaseType.map { PluginManager.shared.supportsContainerSwitching(for: $0) }
                ?? false,
            supportsImport: databaseType.map { PluginManager.shared.supportsImport(for: $0) } ?? false,
            supportsServerDashboard: databaseType.map { ServerDashboardQueryProviderFactory.supportsDashboard(for: $0) }
                ?? false,
            isAIEnabled: AppSettingsManager.shared.ai.enabled
        )
    }

    /// Everything the two resolvers are allowed to know, read once per question.
    ///
    /// `isConnected` is the session's own liveness, which counts a reconnect in progress as up.
    /// The health monitor writes `.connecting` on every attempt of a backoff while the window keeps
    /// showing the session's tabs and rows, and dimming the row for that would be noise.
    func currentContext() -> ToolbarContext {
        let host = self.host
        let state = coordinator?.toolbarState
        return ToolbarContext(
            key: currentVisibilityKey(),
            pane: host?.currentPane ?? .empty,
            isConnected: state.map { Self.hasLiveSession($0.connectionState) } ?? false,
            hasSelectedWorkspace: host?.hasSelectedWorkspace ?? false,
            canToggleTrailingPane: host?.canToggleTrailingPane ?? false,
            canToggleAssistant: host?.canToggleAssistant ?? false,
            pendingChange: state?.pendingChange,
            hasDataPendingChanges: state?.hasDataPendingChanges ?? false,
            blocksAllWrites: state?.safeModeLevel.blocksAllWrites ?? false,
            canAddRow: coordinator?.canAddRow ?? false,
            canRestorePreviousValues: coordinator?.canRewindSelectedTab ?? false,
            canNavigateBack: coordinator?.canNavigateBack ?? false,
            canNavigateForward: coordinator?.canNavigateForward ?? false
        )
    }
}
