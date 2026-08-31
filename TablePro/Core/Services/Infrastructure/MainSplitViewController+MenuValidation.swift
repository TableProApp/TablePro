//
//  MainSplitViewController+MenuValidation.swift
//  TablePro
//

import AppKit

/// Everything the menu bar needs to decide whether a command applies, captured once
/// per validation pass. Keeping it a plain value keeps `isEnabled` pure and testable,
/// the same split `MainWindowToolbar+Validation` uses for the toolbar.
struct MenuValidationContext: Equatable {
    /// Comes from the window's own `ConnectionWindowPhase`, never from the presence of a
    /// coordinator: the coordinator deliberately outlives a lost session so a reconnect keeps
    /// the user's tabs, which made every connection-scoped command stay lit while dialing.
    /// True whenever the window is showing a connection, connected or not, so a pane that
    /// failed to dial can still be dismissed.
    var hasSelectedWorkspace = false
    var isConnected = false
    var isReadOnly = false
    var canUseTableResultCommands = false
    var canUseGridFindCommands = false
    /// Save As writes the selected tab's SQL, so it needs a query tab and not merely a connection.
    var isQueryTab = false
    /// Export Results exports the selected tab's rows, so an empty grid has nothing to offer.
    var hasResultRows = false
    var isCurrentTabEditable = false
    /// Add Row and Duplicate Row stage `DEFAULT` for every column the server fills in, which only
    /// the table's own schema names. Until it lands, the result set's own metadata reports far less,
    /// and an identity column would be staged as NULL that the server refuses.
    var isCurrentTabSchemaResolved = false
    var canRestorePreviousValues = false
    var isQueryExecuting = false
    var hasQueryText = false
    var hasPendingChanges = false
    var hasDataPendingChanges = false
    var hasRowSelection = false
    /// Copy with headers and copy as JSON read the result grid's columns, so they need the data
    /// grid's selection specifically, not the structure grid's.
    var hasDataGridRowSelection = false
    var hasTableSelection = false
    /// Whether the window-level `paste:` fallback would actually paste. AppKit hands a disabled
    /// item its key equivalent regardless, so an item enabled over a handler that returns at its
    /// first guard swallows Command+V with no feedback.
    var canPasteRows = false
    var canCloseOtherTabs = false
    var canCloseTabsForOtherDatabases = false
    var canCloseAllTabs = false
    var canPinResultTab = false
    /// The selected tab's browse history. Separate flags rather than one, because Back and Forward
    /// run out independently and an item that is disabled has to say which one it is.
    var canNavigateBack = false
    var canNavigateForward = false
    var canSaveAsFavorite = false
    var canSwitchSidebarLayout = false
    var canToggleWorkspaceRail = false
    var canShowTableStructure = false
    var canEditViewDefinition = false
    var canCreateDatabase = false
    var canCopyObjects = false
    var canDuplicateDatabase = false
    var hasMaintenanceOperations = false
    var canUndo = false
    var canRedo = false
    var hasEditorForFind = false
    var hasActiveGridFind = false
    var hasImportFormats = false
    var supportsContainerSwitching = false
    var supportsBackup = false
    var supportsRestore = false
    var supportsServerDashboard = false
    var supportsUserManagement = false
    var supportsSchemaSwitching = false
    var canFilterDatabases = false
    var canFavoriteActiveDatabase = false
    var hasDatabaseFilter = false
}

extension MainSplitViewController: NSMenuItemValidation {
    /// A command that reaches the database carries `isConnected` even when it already has a
    /// selection or tab condition of its own. Those conditions are not a substitute for it: a
    /// window that is not connected shows the connecting or unavailable pane with its sidebar and
    /// inspector collapsed, while the coordinator keeps the last tab and selection it saw so a
    /// reconnect can restore them. Without it, Truncate Table and Delete stay lit over an error
    /// screen, pointed at a session that is gone.
    ///
    /// This runs only when the window's content view controller is the responder that claimed the
    /// selector, so a command a nearer responder implements is answered by that responder instead and
    /// never reaches here. The Find commands rely on that: a focused editor claims and validates them
    /// itself, so `hasEditorForFind` only ever decides the unfocused fallback.
    static func isEnabled(_ selector: Selector, context: MenuValidationContext) -> Bool {
        switch selector {
        case #selector(exportTables(_:)),
             #selector(refreshDatabase(_:)),
             #selector(openQuickSwitcher(_:)),
             #selector(toggleQueryHistory(_:)),
             #selector(toggleResults(_:)),
             #selector(showPreviousResult(_:)),
             #selector(showNextResult(_:)),
             #selector(closeResultTab(_:)),
             #selector(focusSidebarFilter(_:)),
             #selector(showERDiagram(_:)),
             #selector(previewFKReference(_:)),
             #selector(goToFirstPage(_:)),
             #selector(goToPreviousPage(_:)),
             #selector(goToNextPage(_:)),
             #selector(goToLastPage(_:)),
             #selector(selectNumberedTab(_:)):
            return context.isConnected

        case #selector(saveDocument(_:)):
            return context.isConnected && !context.isReadOnly && context.hasPendingChanges
        case #selector(saveDocumentAs(_:)):
            return context.isConnected && context.isQueryTab
        case #selector(exportQueryResults(_:)):
            return context.isConnected && context.hasResultRows

        /// AppKit validated New Tab for free while it was its own selector.
        /// `NSWindow.validateUserInterfaceItem` only speaks to the native ones, so this is
        /// ours to enable and disable now. Close went back to `performClose:`, which every
        /// window validates for itself.
        case #selector(newEditorTab(_:)):
            return context.isConnected
        case #selector(closeConnection(_:)):
            return context.hasSelectedWorkspace
        /// Not `isConnected`, unlike the rest of the Database menu. The switcher lists the app's
        /// open connections and the user's saved ones, needs nothing from the session, and is the
        /// command that leaves a connection that has stopped working.
        case #selector(switchConnection(_:)):
            return context.hasSelectedWorkspace
        case #selector(selectNextEditorTab(_:)), #selector(selectPreviousEditorTab(_:)):
            return context.isConnected

        case #selector(closeOtherTabs(_:)):
            return context.canCloseOtherTabs
        case #selector(closeTabsForOtherContainers(_:)):
            return context.canCloseTabsForOtherDatabases
        case #selector(closeAllTabs(_:)):
            return context.canCloseAllTabs

        case #selector(importData(_:)):
            return context.isConnected && !context.isReadOnly && context.hasImportFormats
        case #selector(backupDatabase(_:)):
            return context.isConnected && context.supportsBackup
        case #selector(restoreDatabase(_:)):
            return context.isConnected && context.supportsRestore && !context.isReadOnly

        case #selector(executeQuery(_:)),
             #selector(executeAllStatements(_:)),
             #selector(executeQueryWithoutLimit(_:)),
             #selector(explainQuery(_:)),
             #selector(formatQuery(_:)),
             #selector(explainQueryWithAI(_:)),
             #selector(optimizeQueryWithAI(_:)):
            return context.isConnected && context.hasQueryText
        case #selector(toggleFold(_:)), #selector(foldAll(_:)), #selector(unfoldAll(_:)):
            return context.hasEditorForFind
        case #selector(goToPreviousStatement(_:)), #selector(goToNextStatement(_:)):
            return context.isQueryTab
        case #selector(runStatementAndAdvance(_:)):
            return context.isQueryTab && context.isConnected && context.hasQueryText && !context.isQueryExecuting
        case #selector(cancelQuery(_:)):
            return context.isQueryExecuting
        case #selector(previewSQL(_:)):
            return context.isConnected && context.hasDataPendingChanges
        case #selector(saveAsFavorite(_:)):
            return context.canSaveAsFavorite

        case #selector(addRow(_:)), #selector(duplicateRow(_:)):
            return context.isConnected && context.isCurrentTabEditable && !context.isReadOnly
                && context.isCurrentTabSchemaResolved
        case #selector(restorePreviousValues(_:)):
            return context.isConnected && context.canRestorePreviousValues && !context.isReadOnly
        case #selector(truncateTable(_:)):
            return context.isConnected && context.hasTableSelection && !context.isReadOnly
        case #selector(performFind(_:)):
            return context.hasEditorForFind || (context.isConnected && context.canUseGridFindCommands)
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return context.hasEditorForFind || context.hasActiveGridFind
        case #selector(undo(_:)):
            return context.canUndo
        case #selector(redo(_:)):
            return context.canRedo
        case #selector(copy(_:)):
            return context.hasRowSelection || context.hasTableSelection
        case #selector(copySelectedRows(_:)):
            return context.hasRowSelection
        case #selector(copyRowsWithHeaders(_:)),
             #selector(copyRowsAsJson(_:)):
            return context.hasDataGridRowSelection
        case #selector(paste(_:)):
            return context.isConnected && context.canPasteRows
        case #selector(delete(_:)):
            return context.isConnected && (context.isCurrentTabEditable || context.hasTableSelection)

        case #selector(createNewTable(_:)), #selector(createNewView(_:)):
            return context.isConnected && !context.isReadOnly
        case #selector(createNewDatabase(_:)):
            return context.canCreateDatabase
        case #selector(copyObjectsToDatabase(_:)):
            return context.canCopyObjects
        case #selector(duplicateCurrentDatabase(_:)):
            return context.canDuplicateDatabase
        case #selector(showTableStructure(_:)):
            return context.isConnected && context.canShowTableStructure
        case #selector(editViewDefinition(_:)):
            return context.isConnected && context.canEditViewDefinition
        case #selector(runMaintenanceOperation(_:)):
            return context.isConnected && context.hasMaintenanceOperations
        case #selector(switchToSchema(_:)):
            return context.isConnected && context.supportsSchemaSwitching
        case #selector(setFavoriteDatabaseEnvironment(_:)), #selector(removeFavoriteDatabase(_:)):
            return context.isConnected && context.canFavoriteActiveDatabase
        case #selector(filterDatabases(_:)):
            return context.isConnected && context.canFilterDatabases
        case #selector(showAllDatabases(_:)):
            return context.isConnected && context.canFilterDatabases && context.hasDatabaseFilter
        case #selector(openContainerSwitcher(_:)):
            return context.isConnected && context.supportsContainerSwitching
        case #selector(showServerDashboard(_:)):
            return context.isConnected && context.supportsServerDashboard
        case #selector(showUsersAndRoles(_:)):
            return context.isConnected && context.supportsUserManagement
        case #selector(showQueryInsights(_:)):
            return context.isConnected

        case #selector(toggleFilterBar(_:)):
            return context.isConnected && context.canUseTableResultCommands
        case #selector(pinResult(_:)):
            return context.canPinResultTab
        case #selector(navigateBack(_:)):
            return context.isConnected && context.canNavigateBack
        case #selector(navigateForward(_:)):
            return context.isConnected && context.canNavigateForward
        case #selector(useFlatSidebarLayout(_:)), #selector(useTreeSidebarLayout(_:)):
            return context.canSwitchSidebarLayout
        case #selector(toggleWorkspaceRail(_:)),
             #selector(showPreviousWorkspace(_:)),
             #selector(showNextWorkspace(_:)):
            return context.canToggleWorkspaceRail

        default:
            return true
        }
    }

    /// The workspace-rail facts come from the window in both branches. They are true of the window,
    /// not of the connection it happens to be showing, and reading them off a connection that has
    /// no coordinator left disabled the only menu route to the window's other connections.
    var menuValidationContext: MenuValidationContext {
        guard let actions = commandActions else {
            return MenuValidationContext(
                hasSelectedWorkspace: workspaces.selectedConnectionId != nil,
                canToggleWorkspaceRail: canToggleWorkspaceRail
            )
        }
        return MenuValidationContext(
            hasSelectedWorkspace: workspaces.selectedConnectionId != nil,
            isConnected: isConnected,
            isReadOnly: actions.isReadOnly,
            canUseTableResultCommands: actions.canUseTableResultCommands,
            canUseGridFindCommands: actions.canUseGridFindCommands,
            isQueryTab: actions.isQueryTab,
            hasResultRows: actions.hasResultRows,
            isCurrentTabEditable: actions.isCurrentTabEditable,
            isCurrentTabSchemaResolved: actions.isCurrentTabSchemaResolved,
            canRestorePreviousValues: actions.canRestorePreviousValues,
            isQueryExecuting: actions.isQueryExecuting,
            hasQueryText: actions.hasQueryText,
            hasPendingChanges: actions.hasPendingChanges,
            hasDataPendingChanges: actions.hasDataPendingChanges,
            hasRowSelection: actions.hasRowSelection,
            hasDataGridRowSelection: actions.hasDataGridRowSelection,
            hasTableSelection: actions.hasTableSelection,
            canPasteRows: actions.canPasteRows,
            canCloseOtherTabs: actions.canCloseOtherTabs,
            canCloseTabsForOtherDatabases: actions.canCloseTabsForOtherDatabases,
            canCloseAllTabs: actions.canCloseAllTabs,
            canPinResultTab: actions.canPinResultTab,
            canNavigateBack: actions.canNavigateBack,
            canNavigateForward: actions.canNavigateForward,
            canSaveAsFavorite: actions.canSaveAsFavorite,
            canSwitchSidebarLayout: actions.canSwitchSidebarLayout,
            canToggleWorkspaceRail: canToggleWorkspaceRail,
            canShowTableStructure: actions.canShowTableStructure,
            canEditViewDefinition: actions.canEditViewDefinition,
            canCreateDatabase: actions.canCreateDatabase,
            canCopyObjects: actions.canCopyObjects,
            canDuplicateDatabase: actions.canDuplicateDatabase,
            hasMaintenanceOperations: !actions.maintenanceOperations.isEmpty,
            canUndo: actions.canUndo,
            canRedo: actions.canRedo,
            hasEditorForFind: EditorEventRouter.shared.keyWindowHasEditor,
            hasActiveGridFind: actions.hasActiveGridFind,
            hasImportFormats: !actions.availableImportFormats.isEmpty,
            supportsContainerSwitching: actions.supportsContainerSwitching,
            supportsBackup: actions.supportsBackup,
            supportsRestore: actions.supportsRestore,
            supportsServerDashboard: actions.supportsServerDashboard,
            supportsUserManagement: actions.supportsUserManagement,
            supportsSchemaSwitching: actions.supportsSchemaSwitching,
            canFilterDatabases: actions.canFilterDatabases,
            canFavoriteActiveDatabase: actions.canFavoriteActiveDatabase,
            hasDatabaseFilter: actions.hasDatabaseFilter
        )
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        applyDynamicTitle(to: menuItem)
        guard let action = menuItem.action else { return false }
        if action == #selector(toggleSidebar(_:)) || action == #selector(toggleInspector(_:)) {
            return currentPane == .content
        }
        if action == #selector(setResultView(_:)) { return canShowResultView(menuItem) }
        if action == #selector(requestDisconnect) { return canDisconnect }
        if action == #selector(retryConnection) { return canReconnect }
        return Self.isEnabled(action, context: menuValidationContext)
    }

    /// Assigning a title or state that has not changed still posts an item-changed notification,
    /// which makes an open menu re-lay-out and cancel tracking. Validation runs on every menu
    /// update, so the writes have to be conditional or the menu bar flickers and a click on an
    /// item dismisses the menu instead of firing it.
    private func applyDynamicTitle(to menuItem: NSMenuItem) {
        guard let action = menuItem.action else { return }
        switch action {
        case #selector(toggleSidebar(_:)):
            setTitle(isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar", on: menuItem)
        case #selector(toggleInspector(_:)):
            setTitle(isInspectorVisible ? "Hide Inspector" : "Show Inspector", on: menuItem)
        case #selector(toggleWorkspaceRail(_:)):
            setTitle(isWorkspaceRailEnabled ? "Hide Connections" : "Show Connections", on: menuItem)
        case #selector(undo(_:)):
            setResolvedTitle(commandActions?.resolvedUndoTitle ?? String(localized: "Undo"), on: menuItem)
        case #selector(redo(_:)):
            setResolvedTitle(commandActions?.resolvedRedoTitle ?? String(localized: "Redo"), on: menuItem)
        case #selector(toggleFilterBar(_:)):
            setTitle(commandActions?.isFilterBarVisible == true ? "Hide Filter Bar" : "Show Filter Bar", on: menuItem)
        case #selector(toggleQueryHistory(_:)):
            setTitle(
                commandActions?.isQueryHistoryVisible == true ? "Hide Query History" : "Show Query History",
                on: menuItem
            )
        case #selector(toggleResults(_:)):
            setTitle(commandActions?.isResultsVisible == true ? "Hide Results" : "Show Results", on: menuItem)
        case #selector(pinResult(_:)):
            setTitle(commandActions?.isResultTabPinned == true ? "Unpin Result" : "Pin Result", on: menuItem)
        case #selector(closeTabsForOtherContainers(_:)):
            setResolvedTitle(
                commandActions?.closeTabsForOtherDatabasesTitle
                    ?? String(localized: "Close Tabs for Other Databases"),
                on: menuItem
            )
        case #selector(openContainerSwitcher(_:)):
            setResolvedTitle(
                commandActions?.openContainerSwitcherTitle ?? String(localized: "Open Database…"),
                on: menuItem
            )
        case #selector(setResultView(_:)):
            setState(isCurrentResultView(menuItem) ? .on : .off, on: menuItem)
        case #selector(useFlatSidebarLayout(_:)):
            setState(commandActions?.sidebarLayout == .flat ? .on : .off, on: menuItem)
        case #selector(useTreeSidebarLayout(_:)):
            setState(commandActions?.sidebarLayout == .tree ? .on : .off, on: menuItem)
        default:
            return
        }
    }

    /// The item carries its mode in `representedObject`, so enablement has to see the item rather
    /// than the selector the shared table keys on.
    private func canShowResultView(_ menuItem: NSMenuItem) -> Bool {
        guard let raw = menuItem.representedObject as? String,
              let mode = ResultsViewMode(rawValue: raw) else { return false }
        return commandActions?.availableResultsViewModes.contains(mode) ?? false
    }

    private func isCurrentResultView(_ menuItem: NSMenuItem) -> Bool {
        guard let raw = menuItem.representedObject as? String else { return false }
        return commandActions?.resultsViewMode?.rawValue == raw
    }

    private func setTitle(_ key: String.LocalizationValue, on menuItem: NSMenuItem) {
        setResolvedTitle(String(localized: key), on: menuItem)
    }

    private func setResolvedTitle(_ title: String, on menuItem: NSMenuItem) {
        guard menuItem.title != title else { return }
        menuItem.title = title
    }

    private func setState(_ state: NSControl.StateValue, on menuItem: NSMenuItem) {
        guard menuItem.state != state else { return }
        menuItem.state = state
    }
}
