//
//  MainWindowToolbar+Context.swift
//  TablePro
//

import AppKit
import TableProPluginKit

internal extension MainWindowToolbar {
    // A disconnected workspace has no coordinator, but its window commands must still work.
    var host: MainSplitViewController? {
        windowController ?? coordinator?.splitViewController
    }

    // Read the workspace so a dropped session cannot hide the database control.
    private var databaseType: DatabaseType? {
        host?.workspaces.selected?.connection?.type ?? coordinator?.connection.type
    }

    // Keep transient state out of the key so typing cannot reshape the toolbar.
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
            isAIEnabled: AppSettingsManager.shared.ai.enabled,
            stagesObjectChanges: tab?.tabType == .objectSource && tab?.display.objectRef?.kind == .userType,
            showsDebugItems: debugItemsEnabled()
        )
    }

    // `isConnected` counts a reconnect in progress as up: a backoff writes `.connecting` while the tabs and rows stay on screen.
    func currentContext() -> ToolbarContext {
        let host = self.host
        let state = coordinator?.toolbarState
        let debugger = (host?.contentMode ?? .browse) == .browse ? coordinator?.frontRoutineDebugController : nil
        return ToolbarContext(
            key: currentVisibilityKey(),
            pane: host?.currentPane ?? .empty,
            isConnected: state.map { Self.hasLiveSession($0.connectionState) } ?? false,
            hasSelectedWorkspace: host?.hasSelectedWorkspace ?? false,
            canToggleTrailingPane: host?.canToggleTrailingPane ?? false,
            pendingChange: state?.pendingChange,
            hasDataPendingChanges: state?.hasDataPendingChanges ?? false,
            blocksAllWrites: state?.safeModeLevel.blocksAllWrites ?? false,
            canAddRow: coordinator?.canAddRow ?? false,
            canRestorePreviousValues: coordinator?.canRewindSelectedTab ?? false,
            canNavigateBack: coordinator?.canNavigateBack ?? false,
            canNavigateForward: coordinator?.canNavigateForward ?? false,
            debugCommands: debugger.map { controller in
                Set(PluginDebugCommand.hostCommands.filter { controller.canPerform($0) })
            } ?? [],
            canStopDebugging: debugger?.canStop ?? false,
            isPresentingSheet: coordinator?.isPresentingSheet ?? false
        )
    }
}
