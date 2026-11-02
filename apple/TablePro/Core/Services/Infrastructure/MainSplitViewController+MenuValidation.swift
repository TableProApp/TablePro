//
//  MainSplitViewController+MenuValidation.swift
//  TablePro
//

import AppKit
import TableProPluginKit

// A plain value keeps `isEnabled` pure and testable, the same split `ToolbarContextResolver` uses for the toolbar.
struct MenuValidationContext: Equatable {
    // True for any connection on screen, connected or not, so a pane that failed to dial can still be dismissed.
    var hasSelectedWorkspace = false
    // From `ConnectionWindowPhase`, not the coordinator, which outlives a lost session and kept commands lit while dialing.
    var isConnected = false
    // Session commands belong to the rail, which only Agent mode shows.
    var isAgentMode = false
    // The session the menu item names, else the rail's highlighted one; nil dims Open, Close and Delete Session.
    var agentSessionTarget: AgentSessionStatus?
    // False until the assistant is opened, and with AI off, matching how the pane's own menu dims the same three.
    var hasAssistantConversation = false
    // Separate from `hasAssistantConversation`: a conversation started and never sent has a model and nothing to switch to.
    var hasStoredConversations = false
    var isReadOnly = false
    var canUseTableResultCommands = false
    var canUseGridFindCommands = false
    var canJumpToColumn = false
    var canFocusObjectList = false
    var canFocusEditor = false
    var canFocusResults = false
    var canFocusInspector = false
    var canFocusAssistant = false
    var canPresentHighlightRules = false
    var isQueryTab = false
    var hasResultRows = false
    var canExportDataDictionary = false
    var canInsertRows = false
    var canDeleteRows = false
    // Add and Duplicate Row stage DEFAULT from the table schema; result metadata alone stages NULL the server refuses for identity.
    var isCurrentTabSchemaResolved = false
    var canRestorePreviousValues = false
    var canInsertDocument = false
    var canEditDocument = false
    var isQueryExecuting = false
    // A batch whose COMMIT is on the wire is executing yet unstoppable, and Cmd+. must dim rather than fire into it.
    var isQueryStoppable = false
    var hasQueryText = false
    // A Create Table tab runs its statement with Execute (Cmd+Return), as its old Create Table button did.
    var canCreateDraftTable = false
    var canRunAIQueryActions = false
    var canClearQuery = false
    var canClearResults = false
    var hasPendingChanges = false
    // Save commits an edit still open in the grid before it looks for changes.
    var hasOpenGridEdit = false
    var hasDataPendingChanges = false
    // The selected tab's staged structure edits, or its grid edits; Create Table has nothing to return to.
    var canDiscardChanges = false
    var hasRowSelection = false
    // Copy with headers and Copy as JSON read the data grid's columns, so the structure grid's selection does not count.
    var hasDataGridRowSelection = false
    var hasTableSelection = false
    // Separate from `hasTableSelection`: a view is a valid selection but cannot be truncated.
    var canTruncateSelectedTables = false
    // An engine with no drop DDL for the object must not offer Delete, or the app invents SQL it cannot run.
    var canDropSelectedTables = false
    // Without the row check Delete stayed lit with no selection and fell through to the sidebar's drop path, doing nothing.
    var canDeleteSelectedRows: Bool { canDeleteRows && hasRowSelection }
    // AppKit sends the key equivalent anyway, so enabling over a handler that bails at its first guard swallows Cmd+V silently.
    var canPasteRows = false
    var canCloseOtherTabs = false
    var canCloseTabsForOtherDatabases = false
    var canCloseAllTabs = false
    var canPinEditorTab = false
    var canMoveTabToConnection = false
    var editorTabCount = 0
    // Read off the Select Tab item being validated; nil for any other item.
    var requestedTabNumber: Int?
    // Two tabs across the connections this window can show, the least Control-Tab needs to switch anywhere.
    var hasRecentTabToSwitchTo = false
    // Control-Tab falls back to switching the window's tabs when there is no editor tab to switch to.
    var hasOtherWindowTabs = false
    var canPinResultTab = false
    var canCompareResult = false
    var canShowPreviousResult = false
    var canShowNextResult = false
    var canCloseResultTab = false
    // Separate flags: Back and Forward run out independently and a disabled item has to say which one it is.
    var canNavigateBack = false
    var canNavigateForward = false
    // An engine that cannot skip rows never offers the page commands.
    var canNavigatePages = false
    var canSaveAsFavorite = false
    var canSwitchSidebarLayout = false
    var canToggleWorkspaceRail = false
    // Only embedded engines that lock their database file answer yes, so server connections never show the command at all.
    var canReleaseFileLock = false
    var canShowTableStructure = false
    var canEditViewDefinition = false
    var canShowObjectDDL = false
    var canRefreshMaterializedView = false
    var canEditObjectComment = false
    var canSetSequenceNextValue = false
    var canEditSequence = false
    var canCreateDatabase = false
    var canCreateTable = false
    var canCreateView = false
    var canCreateSequence = false
    var canCreateSchema = false
    var canCreateTableFolder = false
    var canCopyObjects = false
    var canDuplicateDatabase = false
    var canSearchDatabase = false
    var canBuildJoinQuery = false
    var hasMaintenanceOperations = false
    var canUndo = false
    var canRedo = false
    var hasEditorForFind = false
    var hasSelectionForFind = false
    var hasActiveGridFind = false
    var hasImportFormats = false
    var supportsContainerSwitching = false
    var supportsBackup = false
    var supportsRestore = false
    var supportsServerDashboard = false
    var supportsUserManagement = false
    var supportsTableHealth = false
    var supportsSchemaSwitching = false
    // Same rule as the editor bar, so the menu cannot run a statement the bar's button refuses.
    var supportsExplain = false
    // Same rule as the editor bar's Format button.
    var supportsFormatting = false
    var hasSessionContexts = false
    var canFilterDatabases = false
    var canFavoriteActiveDatabase = false
    var hasDatabaseFilter = false
    var canFilterSchemas = false
    var hasSchemaFilter = false
    // Filled only when a Debug menu item is validated; the menu exists only while the module is on.
    var routineDebug = RoutineDebugMenuState()
    var canOpenLiveMessages = false

    // The validation and the window's handler both read it, so a lit Use Selection for Find never lands on an editor with no selection.
    var usesGridSelectionForFind: Bool {
        !hasSelectionForFind && isConnected && canUseGridFindCommands && hasDataGridRowSelection
    }
}

extension MainSplitViewController: NSMenuItemValidation {
    // Nil: not this window's call. An unhandled selector stays lit (Clear Selection did); MenuValidationCoverageTests catches it.
    static func resolvedEnablement(_ selector: Selector, context: MenuValidationContext) -> Bool? {
        guard let answer = ownEnablement(selector, context: context) else { return nil }
        guard context.isAgentMode else { return answer }
        return answer && agentModeSelectors.contains(selector)
    }

    private static func ownEnablement(_ selector: Selector, context: MenuValidationContext) -> Bool? {
        if let find = isFindCommandEnabled(selector, context: context) { return find }
        if let query = isQueryCommandEnabled(selector, context: context) { return query }
        if let chooser = isContainerCommandEnabled(selector, context: context) { return chooser }
        if let creation = isCreationCommandEnabled(selector, context: context) { return creation }
        if let debug = isRoutineDebugCommandEnabled(selector, context: context) { return debug }

        switch selector {
        case #selector(exportTables(_:)),
             #selector(refreshDatabase(_:)),
             #selector(openQuickSwitcher(_:)),
             #selector(toggleQueryHistory(_:)),
             #selector(focusSidebarFilter(_:)),
             #selector(showERDiagram(_:)):
            return context.isConnected

        // The focused data grid answers and validates this itself; reaching the window means no grid has focus.
        case #selector(previewFKReference(_:)):
            return false

        // Agent mode hides the tab strip; on `isConnected` alone these switched tabs behind the conversation or did nothing.
        case #selector(selectNumberedTab(_:)):
            guard context.isConnected, !context.isAgentMode, context.editorTabCount > 1 else { return false }
            guard let number = context.requestedTabNumber else { return true }
            return number >= 1 && number <= context.editorTabCount

        case #selector(goToFirstPage(_:)),
             #selector(goToPreviousPage(_:)),
             #selector(goToNextPage(_:)),
             #selector(goToLastPage(_:)):
            return context.isConnected && context.canNavigatePages

        case #selector(saveDocument(_:)):
            return context.isConnected && !context.isReadOnly && (context.hasPendingChanges || context.hasOpenGridEdit)
        case #selector(discardChanges(_:)):
            return context.isConnected && context.canDiscardChanges
        case #selector(saveDocumentAs(_:)):
            return context.isConnected && context.isQueryTab
        case #selector(exportQueryResults(_:)):
            return context.isConnected && context.hasResultRows

        case #selector(exportDataDictionary(_:)):
            return context.isConnected && context.canExportDataDictionary

        // `NSWindow.validateUserInterfaceItem` only validates native selectors, so New Tab is ours to enable.
        case #selector(newEditorTab(_:)):
            return context.isConnected
        case #selector(closeConnection(_:)):
            return context.hasSelectedWorkspace
        // Not `isConnected`: the switcher needs nothing from the session and is how the user leaves a connection that stopped working.
        case #selector(switchConnection(_:)):
            return context.hasSelectedWorkspace
        case #selector(selectNextEditorTab(_:)), #selector(selectPreviousEditorTab(_:)):
            return context.isConnected && !context.isAgentMode && context.editorTabCount > 1
        case #selector(switchToRecentTab(_:)), #selector(switchToLeastRecentTab(_:)):
            return (context.isConnected && !context.isAgentMode && context.hasRecentTabToSwitchTo)
                || context.hasOtherWindowTabs

        case #selector(closeOtherTabs(_:)):
            return context.canCloseOtherTabs
        case #selector(closeTabsForOtherContainers(_:)):
            return context.canCloseTabsForOtherDatabases
        case #selector(closeAllTabs(_:)):
            return context.canCloseAllTabs
        case #selector(togglePinnedEditorTab(_:)):
            return context.isConnected && !context.isAgentMode && context.canPinEditorTab

        case #selector(importData(_:)), #selector(importDataFormat(_:)):
            return context.isConnected && !context.isReadOnly && context.hasImportFormats
        case #selector(backupDatabase(_:)):
            return context.isConnected && context.supportsBackup
        case #selector(restoreDatabase(_:)):
            return context.isConnected && context.supportsRestore && !context.isReadOnly

        // Not `isConnected`: Agent mode shows the typed prompt while dialling, the state this command is most wanted in.
        case #selector(setContentModeFromMenu(_:)),
             #selector(toggleContentModeFromMenu(_:)):
            return context.hasSelectedWorkspace && AppSettingsManager.shared.ai.enabled
        case #selector(previewSQL(_:)):
            return context.isConnected && context.hasDataPendingChanges
        // Only query tabs have a results pane; `isConnected` alone lit it on seven kinds and wrote an unguarded collapse flag.
        case #selector(toggleResults(_:)):
            return context.isConnected && context.isQueryTab

        case #selector(addRow(_:)), #selector(duplicateRow(_:)):
            return context.isConnected && context.canInsertRows && !context.isReadOnly
                && context.isCurrentTabSchemaResolved
        case #selector(restorePreviousValues(_:)):
            return context.isConnected && context.canRestorePreviousValues && !context.isReadOnly
        case #selector(editDocument(_:)):
            return context.isConnected && context.canEditDocument && !context.isReadOnly
        case #selector(insertDocument(_:)):
            return context.isConnected && context.canInsertDocument && !context.isReadOnly
        case #selector(truncateTable(_:)):
            return context.isConnected && context.canTruncateSelectedTables && !context.isReadOnly
        case #selector(jumpToColumn(_:)):
            return context.isConnected && context.canJumpToColumn
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
            return context.isConnected && (context.canDeleteSelectedRows || context.canDropSelectedTables)

        case #selector(copyObjectsToDatabase(_:)):
            return context.canCopyObjects
        case #selector(duplicateCurrentDatabase(_:)):
            return context.canDuplicateDatabase
        case #selector(searchDatabase(_:)):
            return context.isConnected && context.canSearchDatabase
        case #selector(buildJoinQuery(_:)):
            return context.isConnected && context.canBuildJoinQuery
        case #selector(showTableStructure(_:)),
             #selector(editViewDefinition(_:)),
             #selector(showObjectDDL(_:)),
             #selector(copyObjectDDL(_:)),
             #selector(refreshMaterializedView(_:)),
             #selector(editObjectComment(_:)),
             #selector(setSequenceNextValue(_:)),
             #selector(editSequence(_:)):
            return objectCommandIsEnabled(selector, context: context)
        case #selector(runMaintenanceOperation(_:)):
            return context.isConnected && context.hasMaintenanceOperations
        case #selector(setSafeModeLevel(_:)):
            return context.isConnected
        case #selector(releaseFileLock(_:)):
            return context.isConnected && context.canReleaseFileLock
        case #selector(showServerDashboard(_:)):
            return context.isConnected && context.supportsServerDashboard
        case #selector(showUsersAndRoles(_:)):
            return context.isConnected && context.supportsUserManagement
        case #selector(showQueryInsights(_:)):
            return context.isConnected
        case #selector(showTableHealth(_:)):
            return context.isConnected && context.supportsTableHealth
        case #selector(openLiveMessages(_:)):
            return context.isConnected && !context.isAgentMode && context.canOpenLiveMessages

        case #selector(toggleFilterBar(_:)):
            return context.isConnected && context.canUseTableResultCommands
        case #selector(showHighlightRules(_:)):
            return context.isConnected && context.canPresentHighlightRules
        case #selector(pinResult(_:)):
            return context.canPinResultTab
        case #selector(compareResult(_:)):
            return context.canCompareResult
        case #selector(showPreviousResult(_:)):
            return context.canShowPreviousResult
        case #selector(showNextResult(_:)):
            return context.canShowNextResult
        case #selector(closeResultTab(_:)):
            return context.canCloseResultTab
        case #selector(navigateBack(_:)):
            return context.isConnected && context.canNavigateBack
        case #selector(navigateForward(_:)):
            return context.isConnected && context.canNavigateForward
        case #selector(useFlatSidebarLayout(_:)), #selector(useTreeSidebarLayout(_:)):
            return context.canSwitchSidebarLayout
        case #selector(showTablesSidebarTab(_:)), #selector(showFavoritesSidebarTab(_:)):
            return context.isConnected
        default:
            return isWindowCommandEnabled(selector, context: context)
        }
    }

    // Outside the main switch, which is at its length limit; each chooser follows its own driver capability.
    private static func isContainerCommandEnabled(
        _ selector: Selector,
        context: MenuValidationContext
    ) -> Bool? {
        switch selector {
        case #selector(openContainerSwitcher(_:)):
            return context.isConnected && context.supportsContainerSwitching
        case #selector(switchToSchema(_:)), #selector(openSchemaSwitcher(_:)):
            return context.isConnected && context.supportsSchemaSwitching
        case #selector(switchSessionContext(_:)):
            return context.isConnected && context.hasSessionContexts
        case #selector(setFavoriteDatabaseEnvironment(_:)), #selector(removeFavoriteDatabase(_:)):
            return context.isConnected && context.canFavoriteActiveDatabase
        case #selector(filterDatabases(_:)):
            return context.isConnected && context.canFilterDatabases
        case #selector(showAllDatabases(_:)):
            return context.isConnected && context.canFilterDatabases && context.hasDatabaseFilter
        case #selector(filterSchemas(_:)):
            return context.isConnected && context.canFilterSchemas
        case #selector(showAllSchemas(_:)):
            return context.isConnected && context.canFilterSchemas && context.hasSchemaFilter
        default:
            return nil
        }
    }

    // Agent mode does not draw the debug tab these act on.
    private static func isRoutineDebugCommandEnabled(
        _ selector: Selector,
        context: MenuValidationContext
    ) -> Bool? {
        guard routineDebugSelectors.contains(selector) else { return nil }
        guard !context.isAgentMode else { return false }
        let debug = context.routineDebug
        switch selector {
        case #selector(chooseRoutineToDebug(_:)): return context.isConnected && debug.canChooseRoutine
        case #selector(debugContinue(_:)): return debug.performableCommands.contains(.continueExecution)
        case #selector(debugStepOver(_:)): return debug.performableCommands.contains(.stepOver)
        case #selector(debugStepInto(_:)): return debug.performableCommands.contains(.stepInto)
        case #selector(debugStepOut(_:)): return debug.performableCommands.contains(.stepOut)
        case #selector(debugStop(_:)): return debug.canStop
        case #selector(toggleBreakpoint(_:)): return debug.canToggleBreakpoint
        case #selector(removeAllBreakpoints(_:)): return debug.canRemoveAllBreakpoints
        default: return false
        }
    }

    // The sidebar's add button sends these too. New Folder records local state only, so read-only does not dim it.
    private static func isCreationCommandEnabled(
        _ selector: Selector,
        context: MenuValidationContext
    ) -> Bool? {
        switch selector {
        case #selector(createNewTable(_:)):
            return context.isConnected && !context.isReadOnly && context.canCreateTable
        case #selector(createNewView(_:)):
            return context.isConnected && !context.isReadOnly && context.canCreateView
        case #selector(createNewSequence(_:)):
            return context.isConnected && !context.isReadOnly && context.canCreateSequence
        case #selector(createNewDatabase(_:)):
            return context.canCreateDatabase
        case #selector(createSchema(_:)):
            return context.isConnected && !context.isReadOnly && context.canCreateSchema
        case #selector(createTableFolder(_:)):
            return context.isConnected && context.canCreateTableFolder
        // The schema submenu adds this only for an editable schema; reaching here still needs a writable session.
        case #selector(editCurrentSchema(_:)):
            return context.isConnected && !context.isReadOnly
        default:
            return nil
        }
    }

    // A Focus command that would focus nothing is dimmed: `makeFirstResponder` accepts a view that cannot take the keyboard.
    private static func isWindowCommandEnabled(_ selector: Selector, context: MenuValidationContext) -> Bool? {
        switch selector {
        case #selector(toggleWorkspaceRail(_:)),
             #selector(showPreviousWorkspace(_:)),
             #selector(showNextWorkspace(_:)):
            return context.canToggleWorkspaceRail

        case #selector(focusObjectList(_:)): return context.canFocusObjectList
        case #selector(focusEditor(_:)): return context.canFocusEditor
        case #selector(focusResults(_:)): return context.canFocusResults
        case #selector(focusInspector(_:)): return context.canFocusInspector
        case #selector(focusAssistant(_:)): return context.canFocusAssistant

        // Not `isConnected`: the SQL text is what moves, so a source that lost its connection can still hand it over.
        case #selector(moveTabToConnection(_:)): return context.canMoveTabToConnection

        // Needs a connection on screen, which is what can hold a selection, not merely a window.
        case #selector(clearSelection(_:)): return context.isConnected

        default: return isAgentSessionCommandEnabled(selector, context: context)
        }
    }

    // No live connection needed: the rail stands in every phase and a session outlives its connection.
    private static func isAgentSessionCommandEnabled(
        _ selector: Selector,
        context: MenuValidationContext
    ) -> Bool? {
        switch selector {
        case #selector(newAgentSession(_:)):
            return context.isAgentMode
        case #selector(openAgentSession(_:)), #selector(deleteAgentSession(_:)):
            return context.isAgentMode && context.agentSessionTarget != nil
        case #selector(closeAgentSession(_:)):
            return context.isAgentMode && context.agentSessionTarget?.isEnded == false
        default:
            return isConversationCommandEnabled(selector, context: context)
        }
    }

    // Answers in both modes (one conversation, two surfaces), dimmed on the same conditions as the pane header's menu.
    private static func isConversationCommandEnabled(
        _ selector: Selector,
        context: MenuValidationContext
    ) -> Bool? {
        switch selector {
        case #selector(newAIConversation(_:)):
            return context.hasAssistantConversation
        case #selector(switchAIConversation(_:)), #selector(clearAIConversations(_:)):
            return context.hasAssistantConversation && context.hasStoredConversations
        default:
            return nil
        }
    }

    // Agent mode mounts no browse content, so the window answers there only for the window, the connection and the conversation.
    static let agentModeSelectors: Set<Selector> = [
        #selector(switchConnection(_:)),
        #selector(closeConnection(_:)),
        #selector(setSafeModeLevel(_:)),
        #selector(releaseFileLock(_:)),
        #selector(openContainerSwitcher(_:)),
        #selector(openSchemaSwitcher(_:)),
        #selector(switchToSchema(_:)),
        #selector(switchSessionContext(_:)),
        #selector(setFavoriteDatabaseEnvironment(_:)),
        #selector(removeFavoriteDatabase(_:)),
        #selector(setContentModeFromMenu(_:)),
        #selector(toggleContentModeFromMenu(_:)),
        #selector(newAgentSession(_:)),
        #selector(openAgentSession(_:)),
        #selector(closeAgentSession(_:)),
        #selector(deleteAgentSession(_:)),
        #selector(newAIConversation(_:)),
        #selector(switchAIConversation(_:)),
        #selector(clearAIConversations(_:)),
        #selector(focusAssistant(_:)),
        #selector(focusInspector(_:)),
        #selector(toggleWorkspaceRail(_:)),
        #selector(showPreviousWorkspace(_:)),
        #selector(showNextWorkspace(_:)),
        #selector(switchToRecentTab(_:)),
        #selector(switchToLeastRecentTab(_:)),
        #selector(undo(_:)),
        #selector(redo(_:)),
    ]

    // A command this window does not own stays enabled, which keeps `performClose:` and the system's own items working.
    static func isEnabled(_ selector: Selector, context: MenuValidationContext) -> Bool {
        resolvedEnablement(selector, context: context) ?? true
    }

    // Fallback only: a focused editor or grid claims and validates Find itself, so this decides the result grid's find bar.
    private static func isFindCommandEnabled(_ selector: Selector, context: MenuValidationContext) -> Bool? {
        switch selector {
        case #selector(performFind(_:)), #selector(performFindAndReplace(_:)):
            return context.hasEditorForFind || (context.isConnected && context.canUseGridFindCommands)
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return context.hasEditorForFind || context.hasActiveGridFind
        case #selector(useSelectionForFind(_:)):
            return context.hasSelectionForFind || context.usesGridSelectionForFind
        default:
            return nil
        }
    }

    private static func isQueryCommandEnabled(_ selector: Selector, context: MenuValidationContext) -> Bool? {
        switch selector {
        case #selector(executeQuery(_:)):
            return context.isConnected && (context.hasQueryText || context.canCreateDraftTable)
        case #selector(executeAllStatements(_:)),
             #selector(executeQueryWithoutLimit(_:)):
            return context.isConnected && context.hasQueryText
        case #selector(formatQuery(_:)):
            return context.isConnected && context.hasQueryText && context.supportsFormatting
        case #selector(explainQuery(_:)):
            return QueryCommandAvailability.canExplain(
                isConnected: context.isConnected,
                hasQueryText: context.hasQueryText,
                isExecuting: context.isQueryExecuting,
                supportsExplain: context.supportsExplain
            )
        case #selector(reviewQueryWithAI(_:)),
             #selector(explainQueryWithAI(_:)),
             #selector(optimizeQueryWithAI(_:)):
            return context.canRunAIQueryActions
        case #selector(toggleFold(_:)), #selector(foldAll(_:)), #selector(unfoldAll(_:)):
            return context.hasEditorForFind
        case #selector(removeInvisibleCharacters(_:)):
            return context.hasEditorForFind && context.hasQueryText
        case #selector(goToPreviousStatement(_:)), #selector(goToNextStatement(_:)):
            return context.isQueryTab
        case #selector(runStatementAndAdvance(_:)):
            return context.isQueryTab && context.isConnected && context.hasQueryText && !context.isQueryExecuting
        case #selector(cancelQuery(_:)):
            return context.isQueryExecuting && context.isQueryStoppable
        case #selector(clearQuery(_:)):
            return context.canClearQuery
        case #selector(clearResults(_:)):
            return context.canClearResults
        case #selector(saveAsFavorite(_:)):
            return context.canSaveAsFavorite
        default:
            return nil
        }
    }

    // Same facts as the sidebar's contextual menu, so a command the sidebar omits is dimmed here too.
    private static func objectCommandIsEnabled(_ selector: Selector, context: MenuValidationContext) -> Bool {
        guard context.isConnected else { return false }
        switch selector {
        case #selector(showTableStructure(_:)):
            return context.canShowTableStructure
        case #selector(editViewDefinition(_:)):
            return !context.isReadOnly && context.canEditViewDefinition
        case #selector(showObjectDDL(_:)), #selector(copyObjectDDL(_:)):
            return context.canShowObjectDDL
        case #selector(refreshMaterializedView(_:)):
            return context.canRefreshMaterializedView
        case #selector(editObjectComment(_:)):
            return context.canEditObjectComment
        case #selector(setSequenceNextValue(_:)):
            return context.canSetSequenceNextValue
        case #selector(editSequence(_:)):
            return context.canEditSequence
        default:
            return false
        }
    }

    // Only the connection-level facts, read the way `menuValidationContext` reads them, so a connection off screen can be asked.
    func menuValidationContext(forHosted connectionId: UUID) -> MenuValidationContext? {
        guard let workspace = workspaces.workspace(for: connectionId) else { return nil }
        var context = MenuValidationContext()
        context.hasSelectedWorkspace = true
        context.isConnected = Self.isConnected(phase: workspace.phase, pane: workspace.resolvedPane)
        context.isAgentMode = workspace.resolvedContentMode == .agent
        context.supportsServerDashboard = workspace.sessionState?.coordinator.commandActions?
            .supportsServerDashboard ?? false
        return context
    }

    // Rail facts and Focus Assistant come from the window: off the connection they dimmed with no coordinator or in Agent mode.
    var menuValidationContext: MenuValidationContext {
        let conversations = assistantConversationModel
        guard let actions = commandActions else {
            return MenuValidationContext(
                hasSelectedWorkspace: workspaces.selectedConnectionId != nil,
                isAgentMode: contentMode == .agent,
                agentSessionTarget: agentSessionTarget(for: nil)?.status,
                hasAssistantConversation: conversations != nil,
                hasStoredConversations: conversations?.conversations.isEmpty == false,
                canFocusAssistant: canFocusAssistant,
                canMoveTabToConnection: canMoveSelectedTabToConnection,
                hasOtherWindowTabs: hasOtherWindowTabs,
                canToggleWorkspaceRail: canToggleWorkspaceRail
            )
        }
        return MenuValidationContext(
            hasSelectedWorkspace: workspaces.selectedConnectionId != nil,
            isConnected: isConnected,
            isAgentMode: contentMode == .agent,
            agentSessionTarget: agentSessionTarget(for: nil)?.status,
            hasAssistantConversation: conversations != nil,
            hasStoredConversations: conversations?.conversations.isEmpty == false,
            isReadOnly: actions.isReadOnly,
            canUseTableResultCommands: actions.canUseTableResultCommands,
            canUseGridFindCommands: actions.canUseGridFindCommands,
            canJumpToColumn: actions.canJumpToColumn,
            canFocusObjectList: canFocusObjectList,
            canFocusEditor: canFocusEditor,
            canFocusResults: canFocusResults,
            canFocusInspector: canFocusInspector,
            canFocusAssistant: canFocusAssistant,
            canPresentHighlightRules: actions.canPresentHighlightRules,
            isQueryTab: actions.isQueryTab,
            hasResultRows: actions.hasResultRows,
            canExportDataDictionary: actions.canExportDataDictionary,
            canInsertRows: actions.currentTabAllows(.insert),
            canDeleteRows: actions.currentTabAllows(.delete),
            isCurrentTabSchemaResolved: actions.isCurrentTabSchemaResolved,
            canRestorePreviousValues: actions.canRestorePreviousValues,
            canInsertDocument: actions.canInsertDocument,
            canEditDocument: actions.canEditDocument,
            isQueryExecuting: actions.isQueryExecuting,
            isQueryStoppable: actions.isQueryStoppable,
            hasQueryText: actions.hasQueryText,
            canCreateDraftTable: actions.canCreateDraftTable,
            canRunAIQueryActions: actions.aiQueryActionAvailability.isEnabled,
            canClearQuery: actions.canClearQuery,
            canClearResults: actions.canClearResults,
            hasPendingChanges: actions.hasPendingChanges,
            hasOpenGridEdit: actions.hasOpenGridEdit,
            hasDataPendingChanges: actions.hasDataPendingChanges,
            canDiscardChanges: actions.canDiscardChanges,
            hasRowSelection: actions.hasRowSelection,
            hasDataGridRowSelection: actions.hasDataGridRowSelection,
            hasTableSelection: actions.hasTableSelection,
            canTruncateSelectedTables: actions.canTruncateSelectedTables,
            canDropSelectedTables: actions.canDropSelectedTables,
            canPasteRows: actions.canPasteRows,
            canCloseOtherTabs: actions.canCloseOtherTabs,
            canCloseTabsForOtherDatabases: actions.canCloseTabsForOtherDatabases,
            canCloseAllTabs: actions.canCloseAllTabs,
            canPinEditorTab: actions.canTogglePinnedTab,
            canMoveTabToConnection: canMoveSelectedTabToConnection,
            editorTabCount: actions.openTabCount,
            hasRecentTabToSwitchTo: hasRecentTabToSwitchTo,
            hasOtherWindowTabs: hasOtherWindowTabs,
            canPinResultTab: actions.canPinResultTab,
            canCompareResult: actions.canCompareResult,
            canShowPreviousResult: actions.canShowPreviousResult,
            canShowNextResult: actions.canShowNextResult,
            canCloseResultTab: actions.canCloseResultTab,
            canNavigateBack: actions.canNavigateBack,
            canNavigateForward: actions.canNavigateForward,
            canNavigatePages: actions.canNavigatePages,
            canSaveAsFavorite: actions.canSaveAsFavorite,
            canSwitchSidebarLayout: actions.canSwitchSidebarLayout,
            canToggleWorkspaceRail: canToggleWorkspaceRail,
            canReleaseFileLock: canReleaseFileLock,
            canShowTableStructure: actions.canShowTableStructure,
            canEditViewDefinition: actions.canEditViewDefinition,
            canShowObjectDDL: actions.canShowObjectDDL,
            canRefreshMaterializedView: actions.canRefreshMaterializedView,
            canEditObjectComment: actions.canEditObjectComment,
            canSetSequenceNextValue: actions.canSetSequenceNextValue,
            canEditSequence: actions.canEditSequence,
            canCreateDatabase: actions.canCreateDatabase,
            canCreateTable: actions.canCreateTable,
            canCreateView: actions.canCreateView,
            canCreateSequence: actions.canCreateSequence,
            canCreateSchema: actions.canCreateSchema,
            canCreateTableFolder: canCreateTableFolder,
            canCopyObjects: actions.canCopyObjects,
            canDuplicateDatabase: actions.canDuplicateDatabase,
            canSearchDatabase: actions.canSearchDatabase,
            canBuildJoinQuery: actions.canBuildJoinQuery,
            hasMaintenanceOperations: !actions.maintenanceOperations.isEmpty,
            canUndo: contentMode == .browse ? actions.canUndo : agentUndoManager?.canUndo == true,
            canRedo: contentMode == .browse ? actions.canRedo : agentUndoManager?.canRedo == true,
            hasEditorForFind: EditorEventRouter.shared.keyWindowHasEditor,
            hasSelectionForFind: EditorEventRouter.shared.keyWindowEditorHasSelectionForFind,
            hasActiveGridFind: actions.hasActiveGridFind,
            hasImportFormats: !actions.availableImportFormats.isEmpty,
            supportsContainerSwitching: actions.supportsContainerSwitching,
            supportsBackup: actions.supportsBackup,
            supportsRestore: actions.supportsRestore,
            supportsServerDashboard: actions.supportsServerDashboard,
            supportsUserManagement: actions.supportsUserManagement,
            supportsTableHealth: actions.supportsTableHealth,
            supportsSchemaSwitching: actions.supportsSchemaSwitching,
            supportsExplain: actions.supportsExplain,
            supportsFormatting: actions.supportsFormatting,
            hasSessionContexts: actions.hasSessionContexts,
            canFilterDatabases: actions.canFilterDatabases,
            canFavoriteActiveDatabase: actions.canFavoriteActiveDatabase,
            hasDatabaseFilter: actions.hasDatabaseFilter,
            canFilterSchemas: actions.canFilterSchemas,
            hasSchemaFilter: actions.hasSchemaFilter
        )
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        applyDynamicTitle(to: menuItem)
        guard let action = menuItem.action else { return false }
        // AppKit asks this for the View menu and `validateUserInterfaceItem` for the rest, so a rule must live in both.
        if action == #selector(toggleSidebar(_:)) { return true }
        if action == #selector(toggleInspector(_:)) { return canToggleTrailingPane }
        if action == #selector(toggleAssistant(_:)) { return canToggleAssistant }
        if action == #selector(setResultView(_:)) { return canShowResultView(menuItem) }
        if action == #selector(setSafeModeLevel(_:)) { return canChooseSafeModeLevel(menuItem) }
        if action == #selector(requestDisconnect) { return canDisconnect }
        if action == #selector(retryConnection) { return canReconnect }
        if let zoom = FontSizeZoom.editor.enablement(action, typography: AppSettingsManager.shared.typography) {
            return zoom
        }
        return Self.isEnabled(action, context: menuValidationContext(naming: menuItem))
    }

    // Keyed on the action, not the `representedObject` type: a conversation row's UUID was read as a session id.
    private func menuValidationContext(naming menuItem: NSMenuItem) -> MenuValidationContext {
        var context = menuValidationContext
        guard let action = menuItem.action else { return context }
        if action == #selector(selectNumberedTab(_:)) {
            context.requestedTabNumber = menuItem.tag
        }
        if Self.routineDebugSelectors.contains(action) {
            context.routineDebug = routineDebugMenuState
        }
        if action == #selector(openLiveMessages(_:)) {
            context.canOpenLiveMessages = canOpenLiveMessages
        }
        guard Self.agentSessionSelectors.contains(action) else { return context }
        context.agentSessionTarget = agentSessionTarget(for: menuItem)?.status
        return context
    }

    // The only selectors that may read a session id out of a menu item.
    private static let agentSessionSelectors: Set<Selector> = [
        #selector(openAgentSession(_:)),
        #selector(closeAgentSession(_:)),
        #selector(deleteAgentSession(_:)),
    ]

    private func isCurrentContentMode(_ menuItem: NSMenuItem) -> Bool {
        guard let raw = menuItem.representedObject as? String,
              let mode = ConnectionWorkspaceContentMode(rawValue: raw) else { return false }
        return contentMode == mode
    }

    // Write only on change: any title or state write re-lays out an open menu and cancels tracking, so a click dismissed it.
    private func applyDynamicTitle(to menuItem: NSMenuItem) {
        guard let action = menuItem.action else { return }
        switch action {
        case #selector(toggleSidebar(_:)):
            setTitle(isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar", on: menuItem)
        // In Agent mode the pane toggle names the result column instead of an inspector nobody sees.
        case #selector(toggleInspector(_:)):
            setResolvedTitle(TrailingPaneCommandResolver.paneToggleTitle(trailingPaneCommandContext), on: menuItem)
        case #selector(toggleAssistant(_:)):
            setResolvedTitle(TrailingPaneCommandResolver.assistantToggleTitle(trailingPaneCommandContext), on: menuItem)
        case #selector(toggleWorkspaceRail(_:)):
            setTitle(isWorkspaceRailEnabled ? "Hide Connections" : "Show Connections", on: menuItem)
        case #selector(undo(_:)):
            setResolvedTitle(undoTitle, on: menuItem)
        case #selector(redo(_:)):
            setResolvedTitle(redoTitle, on: menuItem)
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
        case #selector(togglePinnedEditorTab(_:)):
            setResolvedTitle(
                EditorTabContextMenuBuilder.pinTitle(isPinned: commandActions?.isSelectedTabPinned == true),
                on: menuItem
            )
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
        // Driver-named because what it releases differs (DuckDB's file lock is not a server slot).
        case #selector(releaseFileLock(_:)):
            setResolvedTitle(
                ConnectionFileLockAction.commandTitle(connectionId: workspaces.selectedConnectionId)
                    ?? String(localized: "Release File Lock"),
                on: menuItem
            )
        case #selector(setResultView(_:)):
            setState(isCurrentResultView(menuItem) ? .on : .off, on: menuItem)
        case #selector(setContentModeFromMenu(_:)):
            setState(isCurrentContentMode(menuItem) ? .on : .off, on: menuItem)
        case #selector(useFlatSidebarLayout(_:)):
            setState(commandActions?.sidebarLayout == .flat ? .on : .off, on: menuItem)
        case #selector(useTreeSidebarLayout(_:)):
            setState(commandActions?.sidebarLayout == .tree ? .on : .off, on: menuItem)
        case #selector(showTablesSidebarTab(_:)):
            setState(selectedSidebarTab == .tables ? .on : .off, on: menuItem)
        case #selector(showFavoritesSidebarTab(_:)):
            setState(selectedSidebarTab == .favorites ? .on : .off, on: menuItem)
        default:
            return
        }
    }

    // The mode is in `representedObject`, so enablement needs the item, not the selector the shared table keys on.
    private func canShowResultView(_ menuItem: NSMenuItem) -> Bool {
        guard contentMode == .browse else { return false }
        guard let raw = menuItem.representedObject as? String,
              let mode = ResultsViewMode(rawValue: raw) else { return false }
        return commandActions?.availableResultsViewModes.contains(mode) ?? false
    }

    // Uses the status the list is built from: the connection's own floor is blind to Agent mode and enabled a level held at Alert.
    private func canChooseSafeModeLevel(_ menuItem: NSMenuItem) -> Bool {
        guard isConnected,
              let raw = menuItem.representedObject as? String,
              let level = SafeModeLevel(rawValue: raw),
              let status = safeModeStatus else { return false }
        return status.offers(level)
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
