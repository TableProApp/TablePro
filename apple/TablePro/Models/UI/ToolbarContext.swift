//
//  ToolbarContext.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// A value snapshot keeps toolbar validation independent of the live session.
internal struct ToolbarContext: Equatable {
    // A newly opened window can have no selected tab.
    internal let tabKind: TabType?
    internal let resultsMode: ResultsViewMode?
    internal let contentMode: ConnectionWorkspaceContentMode
    internal let pane: ConnectionWindowPane

    // A running query does not make the session unavailable.
    internal let isConnected: Bool
    // A connection is on screen, whether or not it has finished connecting.
    internal let hasSelectedWorkspace: Bool
    internal let canToggleTrailingPane: Bool

    internal let pendingChange: PendingChangeKind?
    // Dirty query files enable Save but have no data edits to preview.
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

    // A type's tab queues changes the commit control saves; every other object tab only reads.
    internal let stagesObjectChanges: Bool

    // Whether the Routine Debugger module puts its controls in the toolbar at all.
    internal let showsDebugItems: Bool
    // A labeled toolbar is a fixed strip of named commands: a content command that cannot act dims in place.
    internal let keepsContentCommandsInPlace: Bool
    // What the selected debug tab can do now; empty and false everywhere else.
    internal let debugCommands: Set<PluginDebugCommand>
    internal let canStopDebugging: Bool
    internal let isPresentingSheet: Bool

    // What the connection supports and the browsed container offers, for the Objects buttons.
    // Enablement only, never visibility.
    internal let canListTables: Bool
    internal let offersViews: Bool
    internal let offersFunctions: Bool
    internal let supportsUserManagement: Bool
    internal let supportsBackup: Bool

    // Only these stable facts may change the toolbar layout or labels.
    internal struct VisibilityKey: Equatable {
        internal let tabKind: TabType?
        internal let resultsMode: ResultsViewMode?
        internal let contentMode: ConnectionWorkspaceContentMode
        internal let isFileBased: Bool
        internal let supportsContainerSwitching: Bool
        internal let supportsImport: Bool
        internal let supportsServerDashboard: Bool
        internal let isAIEnabled: Bool
        internal var stagesObjectChanges = false
        internal var showsDebugItems = false
        internal var keepsContentCommandsInPlace = false
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
            isAIEnabled: isAIEnabled,
            stagesObjectChanges: stagesObjectChanges,
            showsDebugItems: showsDebugItems,
            keepsContentCommandsInPlace: keepsContentCommandsInPlace
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
        stagesObjectChanges: Bool = false,
        showsDebugItems: Bool = false,
        keepsContentCommandsInPlace: Bool = false,
        debugCommands: Set<PluginDebugCommand> = [],
        canStopDebugging: Bool = false,
        isPresentingSheet: Bool = false,
        canListTables: Bool = false,
        offersViews: Bool = false,
        offersFunctions: Bool = false,
        supportsUserManagement: Bool = false,
        supportsBackup: Bool = false
    ) {
        self.tabKind = tabKind
        self.resultsMode = resultsMode
        self.contentMode = contentMode
        self.pane = pane
        self.isConnected = isConnected
        self.hasSelectedWorkspace = hasSelectedWorkspace
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
        self.stagesObjectChanges = stagesObjectChanges
        self.showsDebugItems = showsDebugItems
        self.keepsContentCommandsInPlace = keepsContentCommandsInPlace
        self.debugCommands = debugCommands
        self.canStopDebugging = canStopDebugging
        self.isPresentingSheet = isPresentingSheet
        self.canListTables = canListTables
        self.offersViews = offersViews
        self.offersFunctions = offersFunctions
        self.supportsUserManagement = supportsUserManagement
        self.supportsBackup = supportsBackup
    }

    // Over a key the caller already computed, so the slow-moving facts are read once per context.
    internal init(
        key: VisibilityKey,
        pane: ConnectionWindowPane,
        isConnected: Bool,
        hasSelectedWorkspace: Bool,
        canToggleTrailingPane: Bool,
        pendingChange: PendingChangeKind?,
        hasDataPendingChanges: Bool,
        blocksAllWrites: Bool,
        canAddRow: Bool,
        canRestorePreviousValues: Bool,
        canNavigateBack: Bool,
        canNavigateForward: Bool,
        debugCommands: Set<PluginDebugCommand> = [],
        canStopDebugging: Bool = false,
        isPresentingSheet: Bool = false,
        canListTables: Bool = false,
        offersViews: Bool = false,
        offersFunctions: Bool = false,
        supportsUserManagement: Bool = false,
        supportsBackup: Bool = false
    ) {
        self.init(
            tabKind: key.tabKind,
            resultsMode: key.resultsMode,
            contentMode: key.contentMode,
            pane: pane,
            isConnected: isConnected,
            hasSelectedWorkspace: hasSelectedWorkspace,
            canToggleTrailingPane: canToggleTrailingPane,
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
            isAIEnabled: key.isAIEnabled,
            stagesObjectChanges: key.stagesObjectChanges,
            showsDebugItems: key.showsDebugItems,
            keepsContentCommandsInPlace: key.keepsContentCommandsInPlace,
            debugCommands: debugCommands,
            canStopDebugging: canStopDebugging,
            isPresentingSheet: isPresentingSheet,
            canListTables: canListTables,
            offersViews: offersViews,
            offersFunctions: offersFunctions,
            supportsUserManagement: supportsUserManagement,
            supportsBackup: supportsBackup
        )
    }
}
