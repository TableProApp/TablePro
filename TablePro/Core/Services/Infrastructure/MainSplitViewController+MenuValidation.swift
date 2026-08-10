//
//  MainSplitViewController+MenuValidation.swift
//  TablePro
//

import AppKit

/// Everything the menu bar needs to decide whether a command applies, captured once
/// per validation pass. Keeping it a plain value keeps `isEnabled` pure and testable,
/// the same split `MainWindowToolbar+Validation` uses for the toolbar.
struct MenuValidationContext: Equatable {
    var isConnected = false
    var isReadOnly = false
    var isTableTab = false
    var isCurrentTabEditable = false
    var isQueryExecuting = false
    var hasQueryText = false
    var hasPendingChanges = false
    var hasDataPendingChanges = false
    var hasRowSelection = false
    var hasTableSelection = false
    var canCloseOtherTabs = false
    var canCloseTabsForOtherDatabases = false
    var canCloseAllTabs = false
    var canPinResultTab = false
    var canSaveAsFavorite = false
    var canSwitchSidebarLayout = false
    var canToggleWorkspaceRail = false
    var hasImportFormats = false
    var supportsContainerSwitching = false
    var supportsBackup = false
    var supportsRestore = false
    var supportsServerDashboard = false
    var supportsUserManagement = false
}

extension MainSplitViewController: NSMenuItemValidation {
    static func isEnabled(_ selector: Selector, context: MenuValidationContext) -> Bool {
        switch selector {
        case #selector(openSQLFile(_:)),
             #selector(exportTables(_:)),
             #selector(exportQueryResults(_:)),
             #selector(refreshDatabase(_:)),
             #selector(openQuickSwitcher(_:)),
             #selector(switchConnection(_:)),
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
        case #selector(cancelQuery(_:)):
            return context.isQueryExecuting
        case #selector(previewSQL(_:)):
            return context.isConnected && context.hasDataPendingChanges
        case #selector(saveAsFavorite(_:)):
            return context.canSaveAsFavorite

        case #selector(addRow(_:)), #selector(duplicateRow(_:)):
            return context.isCurrentTabEditable && !context.isReadOnly
        case #selector(truncateTable(_:)):
            return context.hasTableSelection && !context.isReadOnly
        case #selector(copy(_:)):
            return context.hasRowSelection || context.hasTableSelection
        case #selector(copyRowsWithHeaders(_:)), #selector(copyRowsAsJson(_:)):
            return context.hasRowSelection
        case #selector(delete(_:)):
            return context.isCurrentTabEditable || context.hasTableSelection

        case #selector(createNewTable(_:)), #selector(createNewView(_:)):
            return context.isConnected && !context.isReadOnly
        case #selector(openContainerSwitcher(_:)):
            return context.isConnected && context.supportsContainerSwitching
        case #selector(showServerDashboard(_:)):
            return context.isConnected && context.supportsServerDashboard
        case #selector(showUsersAndRoles(_:)):
            return context.isConnected && context.supportsUserManagement

        case #selector(toggleFilterBar(_:)):
            return context.isConnected && context.isTableTab
        case #selector(pinResult(_:)):
            return context.canPinResultTab
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

    var menuValidationContext: MenuValidationContext {
        guard let actions = commandActions else { return MenuValidationContext() }
        return MenuValidationContext(
            isConnected: actions.isConnected,
            isReadOnly: actions.isReadOnly,
            isTableTab: actions.isTableTab,
            isCurrentTabEditable: actions.isCurrentTabEditable,
            isQueryExecuting: actions.isQueryExecuting,
            hasQueryText: actions.hasQueryText,
            hasPendingChanges: actions.hasPendingChanges,
            hasDataPendingChanges: actions.hasDataPendingChanges,
            hasRowSelection: actions.hasRowSelection,
            hasTableSelection: actions.hasTableSelection,
            canCloseOtherTabs: actions.canCloseOtherTabs,
            canCloseTabsForOtherDatabases: actions.canCloseTabsForOtherDatabases,
            canCloseAllTabs: actions.canCloseAllTabs,
            canPinResultTab: actions.canPinResultTab,
            canSaveAsFavorite: actions.canSaveAsFavorite,
            canSwitchSidebarLayout: actions.canSwitchSidebarLayout,
            canToggleWorkspaceRail: actions.canToggleWorkspaceRail,
            hasImportFormats: !actions.availableImportFormats.isEmpty,
            supportsContainerSwitching: actions.supportsContainerSwitching,
            supportsBackup: actions.supportsBackup,
            supportsRestore: actions.supportsRestore,
            supportsServerDashboard: actions.supportsServerDashboard,
            supportsUserManagement: actions.supportsUserManagement
        )
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        applyDynamicTitle(to: menuItem)
        guard let action = menuItem.action else { return false }
        if action == #selector(toggleSidebar(_:)) || action == #selector(toggleInspector(_:)) {
            return currentPane == .content
        }
        return Self.isEnabled(action, context: menuValidationContext)
    }

    private func applyDynamicTitle(to menuItem: NSMenuItem) {
        guard let action = menuItem.action else { return }
        switch action {
        case #selector(toggleSidebar(_:)):
            menuItem.title = isSidebarCollapsed
                ? String(localized: "Show Sidebar")
                : String(localized: "Hide Sidebar")
        case #selector(toggleInspector(_:)):
            menuItem.title = isInspectorVisible
                ? String(localized: "Hide Inspector")
                : String(localized: "Show Inspector")
        case #selector(toggleWorkspaceRail(_:)):
            menuItem.title = isWorkspaceRailEnabled
                ? String(localized: "Hide Workspace Rail")
                : String(localized: "Show Workspace Rail")
        case #selector(pinResult(_:)):
            menuItem.title = commandActions?.isResultTabPinned == true
                ? String(localized: "Unpin Result")
                : String(localized: "Pin Result")
        case #selector(useFlatSidebarLayout(_:)):
            menuItem.state = commandActions?.sidebarLayout == .flat ? .on : .off
        case #selector(useTreeSidebarLayout(_:)):
            menuItem.state = commandActions?.sidebarLayout == .tree ? .on : .off
        default:
            return
        }
    }
}
