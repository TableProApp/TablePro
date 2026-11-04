//
//  ToolbarContextResolver.swift
//  TablePro
//

import AppKit
import TableProPluginKit

// Transient state only dims controls; it never changes the toolbar layout.
internal enum ToolbarContextResolver {
    // Keep items the user added from the customization palette visible.
    internal static let hideableIdentifiers = Set(MainWindowToolbar.defaultItemIdentifiers)

    // The debug controls belong to their module, so all of them, the palette's steps included, may leave the titlebar
    // while it is on; with it off none is vended.
    internal static func hideableItems(showsDebugItems: Bool) -> Set<NSToolbarItem.Identifier> {
        showsDebugItems ? hideableIdentifiers.union(MainWindowToolbar.debugItemIdentifiers) : hideableIdentifiers
    }

    // Constrain hiding here so callers cannot remove user-added items.
    internal static func visibility(for key: ToolbarContext.VisibilityKey) -> ToolbarVisibility {
        ToolbarVisibility(
            hidden: contextualHidden(key).intersection(hideableItems(showsDebugItems: key.showsDebugItems))
        )
    }

    // Use the tab kind so editing cannot change the label width.
    internal static func commitVerb(for tabKind: TabType?) -> String {
        switch tabKind {
        case .createTable:
            String(localized: "Create Table")
        case .usersRoles:
            String(localized: "Apply Changes")
        case .query, .table, .erDiagram, .serverDashboard, .insights, .tableHealth, .objectSource, .versionHistory,
             .tableListing, .routineDebug, .liveMessages, nil:
            String(localized: "Save Changes")
        }
    }

    private static func contextualHidden(_ key: ToolbarContext.VisibilityKey) -> Set<NSToolbarItem.Identifier> {
        var hidden: Set<NSToolbarItem.Identifier> = []

        // File engines already name their sole database in the connection control.
        if key.isFileBased || !key.supportsContainerSwitching {
            hidden.insert(MainWindowToolbar.database)
        }

        // The debug controls exist only while the module is on, and mean something only over a debug tab.
        if key.contentMode == .agent || (key.tabKind != nil && key.tabKind != .routineDebug) {
            hidden.formUnion(MainWindowToolbar.debugItemIdentifiers)
        }

        switch key.contentMode {
        case .agent:
            // Agent mode mounts no browse views to update these controls.
            hidden.insert(MainWindowToolbar.refresh)
            hidden.insert(MainWindowToolbar.saveChanges)
            return hidden
        case .browse:
            hidden.formUnion(browseHidden(key))
            return hidden
        }
    }

    private static func browseHidden(_ key: ToolbarContext.VisibilityKey) -> Set<NSToolbarItem.Identifier> {
        guard let tabKind = key.tabKind else { return [] }
        switch tabKind {
        case .createTable:
            // A definition that is not on the server yet has nothing to reload.
            return [MainWindowToolbar.refresh]
        case .objectSource where key.stagesObjectChanges:
            return []
        case .serverDashboard, .insights, .tableHealth, .objectSource, .versionHistory, .tableListing:
            // None of these can stage a change, so the commit control could only ever be dim.
            return [MainWindowToolbar.saveChanges]
        case .routineDebug, .liveMessages:
            // A debug run or a live subscription has nothing to reload or commit; its own controls take that place.
            return [MainWindowToolbar.refresh, MainWindowToolbar.saveChanges]
        case .query, .table, .usersRoles, .erDiagram:
            return []
        }
    }

    // Agent mode mounts no browse content. `MenuContentModeParityTests` holds these to the menu bar's `agentModeSelectors`.
    private static let browseContentIdentifiers: Set<NSToolbarItem.Identifier> = [
        MainWindowToolbar.refresh,
        MainWindowToolbar.saveChanges,
        MainWindowToolbar.addRow,
        MainWindowToolbar.restorePreviousValues,
        MainWindowToolbar.previewSQL,
        MainWindowToolbar.results,
        MainWindowToolbar.history,
        MainWindowToolbar.newTab,
        MainWindowToolbar.quickSwitcher,
        MainWindowToolbar.exportTables,
        MainWindowToolbar.importTables,
        MainWindowToolbar.navigateBack,
        MainWindowToolbar.navigateForward,
    ]

    // The same commands as the menu bar's `sheetCommandSelectors`: a window with a sheet attached takes no second one.
    private static let sheetCommandIdentifiers: Set<NSToolbarItem.Identifier> = [
        MainWindowToolbar.saveChanges,
        MainWindowToolbar.previewSQL,
        MainWindowToolbar.exportTables,
        MainWindowToolbar.importTables,
        MainWindowToolbar.restorePreviousValues,
    ]

    // The `default:` is false: an unconditional true left Query History live and inert over a window that never connected.
    internal static func isEnabled(
        _ identifier: NSToolbarItem.Identifier,
        context: ToolbarContext
    ) -> Bool {
        if context.contentMode == .agent, browseContentIdentifiers.contains(identifier) { return false }
        if context.isPresentingSheet, sheetCommandIdentifiers.contains(identifier) { return false }
        switch identifier {
        case MainWindowToolbar.connection:
            // Switch Connection is the window's command, so it answers before a session exists.
            return true
        case MainWindowToolbar.database:
            return context.isConnected && !context.isFileBased && context.supportsContainerSwitching
        case MainWindowToolbar.actions:
            // Each Actions menu entry validates itself through the responder chain.
            return context.hasSelectedWorkspace && context.pane != .empty
        case MainWindowToolbar.refresh:
            return context.isConnected
        case MainWindowToolbar.saveChanges:
            return context.pendingChange != nil && context.isConnected && !context.blocksAllWrites
        case MainWindowToolbar.safeMode:
            // Safe Mode stays available for as long as the session does.
            return context.isConnected
        case MainWindowToolbar.inspector:
            // A disconnected window must still let the user close its inspector.
            return context.canToggleTrailingPane
        case MainWindowToolbar.addRow:
            return context.isConnected && context.canAddRow
        case MainWindowToolbar.restorePreviousValues:
            return context.isConnected && context.canRestorePreviousValues
        case MainWindowToolbar.navigateBack:
            return context.isConnected && context.canNavigateBack
        case MainWindowToolbar.navigateForward:
            return context.isConnected && context.canNavigateForward
        case MainWindowToolbar.previewSQL:
            return context.isConnected && context.hasDataPendingChanges
        case MainWindowToolbar.results:
            // Only query tabs have a results pane to toggle.
            return context.isConnected && context.tabKind == .query
        case MainWindowToolbar.history:
            return context.isConnected
        case MainWindowToolbar.exportTables, MainWindowToolbar.newTab, MainWindowToolbar.quickSwitcher:
            return context.isConnected
        case MainWindowToolbar.importTables:
            return context.isConnected && !context.blocksAllWrites && context.supportsImport
        case MainWindowToolbar.debugContinue:
            return context.debugCommands.contains(.continueExecution)
        case MainWindowToolbar.debugStepOver:
            return context.debugCommands.contains(.stepOver)
        case MainWindowToolbar.debugStepInto:
            return context.debugCommands.contains(.stepInto)
        case MainWindowToolbar.debugStepOut:
            return context.debugCommands.contains(.stepOut)
        case MainWindowToolbar.debugStop:
            return context.canStopDebugging
        default:
            return false
        }
    }
}
