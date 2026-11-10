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
        let objects = objectKindFacts()
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
            isPresentingSheet: coordinator?.isPresentingSheet ?? false,
            canListTables: objects.canListTables,
            offersViews: objects.offersViews,
            offersFunctions: objects.offersFunctions,
            supportsUserManagement: objects.supportsUserManagement,
            supportsBackup: objects.supportsBackup
        )
    }

    // Every window update runs a validation pass, keystrokes included, and the listing is a plugin call that builds
    // the whole statement. So the facts are read only while an Objects button is in this toolbar, where it shows them,
    // and then once per browsed container and session.
    func objectKindFacts() -> ObjectKindFacts {
        let objectKinds = Set(Self.objectKindItemIdentifiers)
        guard let coordinator, managedToolbar.items.contains(where: { objectKinds.contains($0.itemIdentifier) })
        else { return ObjectKindFacts() }
        let source = ObjectKindFactsSource(coordinator: coordinator)
        if let cached = objectKindFactsCache, cached.source.matches(source) {
            return cached.facts
        }
        let offered = coordinator.browsedObjectKinds()
        let facts = ObjectKindFacts(
            canListTables: coordinator.allTablesListing() != nil,
            offersViews: offered.contains(.view),
            offersFunctions: offered.contains(.function),
            supportsUserManagement: coordinator.commandActions?.supportsUserManagement == true,
            supportsBackup: coordinator.commandActions?.supportsBackup == true
        )
        objectKindFactsCache = ObjectKindFactsCache(source: source, facts: facts)
        return facts
    }
}

// What the Objects buttons ask of the connection and the browsed container.
internal struct ObjectKindFacts: Equatable {
    var canListTables = false
    var offersViews = false
    var offersFunctions = false
    var supportsUserManagement = false
    var supportsBackup = false
}

// What the facts were read from. A database or schema switch moves the scope, a reconnect installs a new driver, and a
// load or refresh of the container replaces its lists, so each of them reads the facts again.
internal struct ObjectKindFactsSource {
    let scope: DatabaseScope
    // Weak, so a driver a reconnect released cannot pass for a new one allocated at its address.
    weak var driver: (any DatabaseDriver)?
    // Users and Backup answer through the command actions, which a window gains once its content appears.
    let hasCommandActions: Bool
    // Only these two lists decide Views and Functions. A list nothing replaced compares by its storage, not by walking it.
    let tables: MetadataLoadState<[TableInfo]>
    let routines: MetadataLoadState<[RoutineInfo]>

    @MainActor
    init(coordinator: MainContentCoordinator) {
        let scope = coordinator.browsedObjectsScope
        let tree = DatabaseTreeMetadataService.shared
        self.scope = scope
        driver = DatabaseManager.shared.driver(for: coordinator.connectionId)
        hasCommandActions = coordinator.commandActions != nil
        tables = tree.tablesLoadState(connectionId: scope.connectionId, database: scope.database, schema: scope.schema)
        routines = tree.routinesLoadState(connectionId: scope.connectionId, database: scope.database, schema: scope.schema)
    }

    func matches(_ other: ObjectKindFactsSource) -> Bool {
        scope == other.scope && driver === other.driver && hasCommandActions == other.hasCommandActions
            && tables == other.tables && routines == other.routines
    }
}

internal struct ObjectKindFactsCache {
    let source: ObjectKindFactsSource
    let facts: ObjectKindFacts
}
