//
//  MainSplitViewController+MenuValidation.swift
//  TablePro
//

import AppKit

/// Everything the menu bar needs to decide whether a command applies, captured once
/// per validation pass. Keeping it a plain value keeps `isEnabled` pure and testable,
/// the same split `ToolbarContextResolver` uses for the toolbar.
struct MenuValidationContext: Equatable {
    /// Comes from the window's own `ConnectionWindowPhase`, never from the presence of a
    /// coordinator: the coordinator deliberately outlives a lost session so a reconnect keeps
    /// the user's tabs, which made every connection-scoped command stay lit while dialing.
    /// True whenever the window is showing a connection, connected or not, so a pane that
    /// failed to dial can still be dismissed.
    var hasSelectedWorkspace = false
    var isConnected = false
    /// Whether the connection on screen is showing its agent rather than its objects. The session
    /// commands are the rail's, and the rail is only there in Agent mode.
    var isAgentMode = false
    /// The session a session command acts on: the one its menu item names, or the one the rail has
    /// highlighted. Nil when there is none, which is what dims Open, Close and Delete Session.
    var agentSessionTarget: AgentSessionStatus?
    /// Whether the connection on screen has an assistant conversation for its three commands to act
    /// on. False until something opens the assistant, and false with the AI feature off, which is
    /// what the pane's own menu already says by dimming the same three.
    var hasAssistantConversation = false
    /// Whether any conversation has been stored, which is what Conversation History lists and what
    /// Clear Recents throws away. Separate from the one above: a conversation started and never sent
    /// in has a model and nothing to switch to.
    var hasStoredConversations = false
    var isReadOnly = false
    var canUseTableResultCommands = false
    var canUseGridFindCommands = false
    /// Jump to Column reads the mounted data grid, so it needs one on screen with columns to list.
    var canJumpToColumn = false
    /// Each Focus command names a pane, so each needs that pane to exist and to hold a view that can
    /// take the keyboard. A command that focuses nothing is a command that should be dimmed.
    var canFocusObjectList = false
    var canFocusEditor = false
    var canFocusResults = false
    var canFocusInspector = false
    var canFocusAssistant = false
    var canPresentHighlightRules = false
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
    /// Whether Stop still has something to act on. A batch whose `COMMIT` is on the wire is
    /// executing and unstoppable at the same time, and `Cmd+.` must dim rather than fire into it.
    var isQueryStoppable = false
    var hasQueryText = false
    var canClearQuery = false
    var canClearResults = false
    var hasPendingChanges = false
    var hasDataPendingChanges = false
    var hasRowSelection = false
    /// Copy with headers and copy as JSON read the result grid's columns, so they need the data
    /// grid's selection specifically, not the structure grid's.
    var hasDataGridRowSelection = false
    var hasTableSelection = false
    /// Whether every selected object is one the engine can truncate. Separate from
    /// `hasTableSelection` because a view is a perfectly good selection and a hopeless truncate.
    var canTruncateSelectedTables = false
    /// Whether every selected object is one the engine has a drop statement for. An engine with
    /// no DDL for it must not be offered Delete, or the app invents SQL it cannot run.
    var canDropSelectedTables = false
    /// An editable tab only answers Delete when a row is selected. Without the row check the item
    /// stayed enabled over a grid with no selection, fell through to the sidebar's drop path and
    /// did nothing there.
    var canDeleteSelectedRows: Bool { isCurrentTabEditable && hasRowSelection }
    /// Whether the window-level `paste:` fallback would actually paste. AppKit hands a disabled
    /// item its key equivalent regardless, so an item enabled over a handler that returns at its
    /// first guard swallows Command+V with no feedback.
    var canPasteRows = false
    var canCloseOtherTabs = false
    var canCloseTabsForOtherDatabases = false
    var canCloseAllTabs = false
    /// How many editor tabs the connection on screen has open.
    var editorTabCount = 0
    /// The tab a Select Tab item names, read off the item being validated. Nil when the item is not
    /// one of them.
    var requestedTabNumber: Int?
    /// Whether the connections this window can show hold two tabs between them, which is the least
    /// Control-Tab needs to switch anywhere.
    var hasRecentTabToSwitchTo = false
    /// Whether the window sits in a window tab group, where Control-Tab falls back to switching the
    /// window's tabs when there is no editor tab to switch to.
    var hasOtherWindowTabs = false
    var canPinResultTab = false
    /// The selected tab's browse history. Separate flags rather than one, because Back and Forward
    /// run out independently and an item that is disabled has to say which one it is.
    var canNavigateBack = false
    var canNavigateForward = false
    /// First, Previous, Next and Last Page, which an engine that cannot skip rows never offers.
    var canNavigatePages = false
    var canSaveAsFavorite = false
    var canSwitchSidebarLayout = false
    var canToggleWorkspaceRail = false
    /// Whether the connection's driver is holding an operating-system resource it can hand back
    /// without ending the session. Only the embedded engines that lock their database file answer
    /// yes, so the command is absent for every server-backed connection rather than present and
    /// disabled: a command that can never apply to a connection is not a command it is missing.
    var canReleaseFileLock = false
    var canShowTableStructure = false
    var canEditViewDefinition = false
    var canShowObjectDDL = false
    var canRefreshMaterializedView = false
    var canEditObjectComment = false
    var canCreateDatabase = false
    var canCopyObjects = false
    var canDuplicateDatabase = false
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
    var supportsServerSideExport = false
    var supportsServerDashboard = false
    var supportsUserManagement = false
    var supportsSchemaSwitching = false
    /// Whether the engine declares an EXPLAIN variant. Read through the same rule the editor bar
    /// uses, so the menu item cannot run a statement the bar's button refuses to.
    var supportsExplain = false
    var hasSessionContexts = false
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
    /// What this window has to say about a command, or nil when the command is not its to decide.
    ///
    /// Nil is the whole point. A menu item whose selector this controller implements and that has no
    /// arm here is a command that stays enabled over a window that cannot run it, and the suite is
    /// green either way: that shipped as Clear Selection, lit on a window with nothing selected and
    /// nothing to clear. `MenuValidationCoverageTests` reads the nil to say so.
    static func resolvedEnablement(_ selector: Selector, context: MenuValidationContext) -> Bool? {
        if context.isAgentMode, browseContentSelectors.contains(selector) { return false }
        if let find = isFindCommandEnabled(selector, context: context) { return find }
        if let query = isQueryCommandEnabled(selector, context: context) { return query }
        if let chooser = isContainerCommandEnabled(selector, context: context) { return chooser }

        switch selector {
        case #selector(exportTables(_:)),
             #selector(refreshDatabase(_:)),
             #selector(openQuickSwitcher(_:)),
             #selector(toggleQueryHistory(_:)),
             #selector(showPreviousResult(_:)),
             #selector(showNextResult(_:)),
             #selector(closeResultTab(_:)),
             #selector(focusSidebarFilter(_:)),
             #selector(showERDiagram(_:)),
             #selector(previewFKReference(_:)):
            return context.isConnected

        /// Each of these moves the selection of a strip, so each needs one on screen, which Agent mode
        /// does not show, with a tab for the command to reach. Left on `isConnected` alone they
        /// changed the selected tab behind the conversation, and did nothing at all with one tab or
        /// for a number past the last tab.
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

        case #selector(importData(_:)), #selector(importDataFormat(_:)):
            return context.isConnected && !context.isReadOnly && context.hasImportFormats
        case #selector(backupDatabase(_:)):
            return context.isConnected && context.supportsBackup
        case #selector(restoreDatabase(_:)):
            return context.isConnected && context.supportsRestore && !context.isReadOnly
        case #selector(serverSideExport(_:)):
            /// The server does the writing, so this is a write on the connection and a read-only
            /// Safe Mode has to stop it the same way Restore is stopped.
            return context.isConnected && context.supportsServerSideExport && !context.isReadOnly

        /// Reachable while the connection is still dialling: agent mode draws the prompt the user
        /// typed, which is exactly what they are waiting with, so gating on `isConnected` would make
        /// the command dead in the one state it is most wanted.
        case #selector(setContentModeFromMenu(_:)),
             #selector(toggleContentModeFromMenu(_:)):
            return context.hasSelectedWorkspace && AppSettingsManager.shared.ai.enabled
        case #selector(previewSQL(_:)):
            return context.isConnected && context.hasDataPendingChanges
        /// The results pane belongs to the query editor. The shipped rule was `isConnected` alone,
        /// so the command was lit on the seven kinds that have no results pane and `toggleResults`
        /// then wrote a collapse flag with no tab-kind guard behind it. This is the rule the
        /// toolbar's own item answers by.
        case #selector(toggleResults(_:)):
            return context.isConnected && context.isQueryTab

        case #selector(addRow(_:)), #selector(duplicateRow(_:)):
            return context.isConnected && context.isCurrentTabEditable && !context.isReadOnly
                && context.isCurrentTabSchemaResolved
        case #selector(restorePreviousValues(_:)):
            return context.isConnected && context.canRestorePreviousValues && !context.isReadOnly
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

        case #selector(createNewTable(_:)), #selector(createNewView(_:)):
            return context.isConnected && !context.isReadOnly
        case #selector(createNewDatabase(_:)):
            return context.canCreateDatabase
        case #selector(copyObjectsToDatabase(_:)):
            return context.canCopyObjects
        case #selector(duplicateCurrentDatabase(_:)):
            return context.canDuplicateDatabase
        case #selector(showTableStructure(_:)),
             #selector(editViewDefinition(_:)),
             #selector(showObjectDDL(_:)),
             #selector(copyObjectDDL(_:)),
             #selector(refreshMaterializedView(_:)),
             #selector(editObjectComment(_:)):
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

        case #selector(toggleFilterBar(_:)):
            return context.isConnected && context.canUseTableResultCommands
        case #selector(showHighlightRules(_:)):
            return context.isConnected && context.canPresentHighlightRules
        case #selector(pinResult(_:)):
            return context.canPinResultTab
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

    /// What the window is pointed at inside the connection: which database, which schema, which
    /// session context, and which databases the tree shows at all. Each is a chooser the driver may
    /// not offer, so each follows its own capability rather than the session alone.
    ///
    /// Answered before the main switch rather than inside it, because that switch is at its length
    /// limit and this is a domain of its own.
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
        default:
            return nil
        }
    }

    /// The commands the window answers for itself rather than on behalf of the connection it shows.
    ///
    /// Each Focus command follows the pane it names, so one that would focus nothing is dimmed
    /// rather than silently doing nothing: `makeFirstResponder` accepts a view that cannot take the
    /// keyboard and reports success. Agent mode's session commands are the window's own too, and are
    /// answered by the helper below rather than inline, because this switch is at its length limit.
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

        /// Escape clears the selection wherever one is, so the command needs a window showing a
        /// connection and something that can hold a selection, not merely a window.
        case #selector(clearSelection(_:)): return context.isConnected

        /// Unconditional on purpose, and stated rather than left to the fall-through. The window is
        /// the last responder to answer these, and what it does with them is change the editor font
        /// size, which is an app setting and needs no session. A focused diagram claims them first.
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)): return true

        default: return isAgentSessionCommandEnabled(selector, context: context)
        }
    }

    /// Agent mode's session commands, which need the rail on screen and, New Session apart, a session
    /// to act on. None of them needs a live connection: the rail stands in every phase, a session
    /// outlives the connection's, and a conversation is worth reading with the database down.
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

    /// The assistant's three conversation commands, which answer in both modes: the conversation is
    /// one thing shown two ways, in the trailing pane while browsing and in the content column in
    /// Agent mode, so a command that acts on it applies wherever it is drawn.
    ///
    /// Each needs the assistant to have been opened, because that is what creates the model they
    /// write to. Switching and clearing need a stored conversation on top of that, which is the same
    /// pair of conditions the pane header's own menu is dimmed by.
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

    /// The commands that act on the browse content, which Agent mode does not mount.
    ///
    /// Every one of them has a toolbar twin whose `ToolbarContextResolver` arm answers no in Agent
    /// mode, and the menu bar is where most of them now live, so leaving them lit here would be the
    /// same defect one surface deeper: Refresh over a grid that is not there, Save over a commit gate
    /// frozen at the moment the mode changed, Command Y flipping a persisted flag for a drawer that
    /// is not mounted, and New Tab opening a tab behind the conversation.
    ///
    /// A set rather than an arm each, because the rule is one rule. `MenuContentModeParityTests`
    /// holds the two surfaces' answers together and derives this list back out of the toolbar, so a
    /// browse-only item added there without an entry here fails rather than ships enabled.
    ///
    /// What is deliberately not here: Switch Connection, Close Connection, Safe Mode, the two mode
    /// commands, the session commands and the conversation commands. Each of those acts on the
    /// window or on the session, both of which Agent mode still has.
    private static let browseContentSelectors: Set<Selector> = [
        #selector(refreshDatabase(_:)),
        #selector(saveDocument(_:)),
        #selector(addRow(_:)),
        #selector(restorePreviousValues(_:)),
        #selector(previewSQL(_:)),
        #selector(toggleResults(_:)),
        #selector(toggleQueryHistory(_:)),
        #selector(newEditorTab(_:)),
        #selector(openQuickSwitcher(_:)),
        #selector(exportTables(_:)),
        /// Both spellings of one command: the leaf that takes the driver's first format, and the
        /// row of the list that names another. One without the other would leave the list live over
        /// a leaf that is dim.
        #selector(importData(_:)),
        #selector(importDataFormat(_:)),
        #selector(showServerDashboard(_:)),
        #selector(navigateBack(_:)),
        #selector(navigateForward(_:)),
    ]

    /// What AppKit is told. A command this window does not own is left enabled, which is what keeps
    /// `performClose:` and the rest of the system's own items working.
    static func isEnabled(_ selector: Selector, context: MenuValidationContext) -> Bool {
        resolvedEnablement(selector, context: context) ?? true
    }

    /// The Edit menu's Find commands, which are the window's last-resort answer. A focused editor claims and
    /// validates them itself, so what these decide is only what happens when nothing nearer took the selector:
    /// Find falls back to the result grid's find bar, and the two editor-only commands dim.
    private static func isFindCommandEnabled(_ selector: Selector, context: MenuValidationContext) -> Bool? {
        switch selector {
        case #selector(performFind(_:)):
            return context.hasEditorForFind || (context.isConnected && context.canUseGridFindCommands)
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return context.hasEditorForFind || context.hasActiveGridFind
        case #selector(performFindAndReplace(_:)):
            return context.hasEditorForFind
        case #selector(useSelectionForFind(_:)):
            return context.hasSelectionForFind
        default:
            return nil
        }
    }

    /// The commands that act on the selected tab's editor and the statements in it.
    private static func isQueryCommandEnabled(_ selector: Selector, context: MenuValidationContext) -> Bool? {
        switch selector {
        case #selector(executeQuery(_:)),
             #selector(executeAllStatements(_:)),
             #selector(executeQueryWithoutLimit(_:)),
             #selector(formatQuery(_:)):
            return context.isConnected && context.hasQueryText
        case #selector(explainQuery(_:)):
            return QueryCommandAvailability.canExplain(
                isConnected: context.isConnected,
                hasQueryText: context.hasQueryText,
                isExecuting: context.isQueryExecuting,
                supportsExplain: context.supportsExplain
            )
        /// Both hand their statement to the assistant, which will not open with the feature off.
        /// They validated on the query alone, so with AI off the item stayed enabled, the shortcut
        /// fired and nothing happened at all: no pane, no alert, nothing.
        case #selector(explainQueryWithAI(_:)),
             #selector(optimizeQueryWithAI(_:)):
            return context.isConnected && context.hasQueryText && AppSettingsManager.shared.ai.enabled
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

    /// The commands that act on the object selected in the sidebar. They answer on the same facts
    /// the sidebar's own contextual menu reads, so a command the sidebar omits is dimmed here rather
    /// than enabled over an object it cannot act on.
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
        default:
            return false
        }
    }

    /// The workspace-rail facts come from the window in both branches. They are true of the window,
    /// not of the connection it happens to be showing, and reading them off a connection that has
    /// no coordinator left disabled the only menu route to the window's other connections.
    ///
    /// Focus Assistant is the window's too. A window opened straight into Agent mode draws the
    /// conversation in its content column and never mounts the browse content that sets up the
    /// command actions, so read from them, the one command that reaches its composer was dimmed.
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
            isCurrentTabEditable: actions.isCurrentTabEditable,
            isCurrentTabSchemaResolved: actions.isCurrentTabSchemaResolved,
            canRestorePreviousValues: actions.canRestorePreviousValues,
            isQueryExecuting: actions.isQueryExecuting,
            isQueryStoppable: actions.isQueryStoppable,
            hasQueryText: actions.hasQueryText,
            canClearQuery: actions.canClearQuery,
            canClearResults: actions.canClearResults,
            hasPendingChanges: actions.hasPendingChanges,
            hasDataPendingChanges: actions.hasDataPendingChanges,
            hasRowSelection: actions.hasRowSelection,
            hasDataGridRowSelection: actions.hasDataGridRowSelection,
            hasTableSelection: actions.hasTableSelection,
            canTruncateSelectedTables: actions.canTruncateSelectedTables,
            canDropSelectedTables: actions.canDropSelectedTables,
            canPasteRows: actions.canPasteRows,
            canCloseOtherTabs: actions.canCloseOtherTabs,
            canCloseTabsForOtherDatabases: actions.canCloseTabsForOtherDatabases,
            canCloseAllTabs: actions.canCloseAllTabs,
            editorTabCount: actions.openTabCount,
            hasRecentTabToSwitchTo: hasRecentTabToSwitchTo,
            hasOtherWindowTabs: hasOtherWindowTabs,
            canPinResultTab: actions.canPinResultTab,
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
            canCreateDatabase: actions.canCreateDatabase,
            canCopyObjects: actions.canCopyObjects,
            canDuplicateDatabase: actions.canDuplicateDatabase,
            hasMaintenanceOperations: !actions.maintenanceOperations.isEmpty,
            canUndo: actions.canUndo,
            canRedo: actions.canRedo,
            hasEditorForFind: EditorEventRouter.shared.keyWindowHasEditor,
            hasSelectionForFind: EditorEventRouter.shared.keyWindowEditorHasSelectionForFind,
            hasActiveGridFind: actions.hasActiveGridFind,
            hasImportFormats: !actions.availableImportFormats.isEmpty,
            supportsContainerSwitching: actions.supportsContainerSwitching,
            supportsBackup: actions.supportsBackup,
            supportsRestore: actions.supportsRestore,
            supportsServerSideExport: actions.supportsServerSideExport,
            supportsServerDashboard: actions.supportsServerDashboard,
            supportsUserManagement: actions.supportsUserManagement,
            supportsSchemaSwitching: actions.supportsSchemaSwitching,
            supportsExplain: actions.supportsExplain,
            hasSessionContexts: actions.hasSessionContexts,
            canFilterDatabases: actions.canFilterDatabases,
            canFavoriteActiveDatabase: actions.canFavoriteActiveDatabase,
            hasDatabaseFilter: actions.hasDatabaseFilter
        )
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        applyDynamicTitle(to: menuItem)
        guard let action = menuItem.action else { return false }
        /// AppKit asks this method for the View menu and `validateUserInterfaceItem` for everything
        /// else, so a rule that lives in only one of them holds for only half the routes to the
        /// command. The sidebar is the window's and stands in every phase; the two trailing
        /// surfaces need a session to open and none to close.
        if action == #selector(toggleSidebar(_:)) { return true }
        if action == #selector(toggleInspector(_:)) { return canToggleTrailingPane }
        if action == #selector(toggleAssistant(_:)) { return canToggleAssistant }
        if action == #selector(setResultView(_:)) { return canShowResultView(menuItem) }
        if action == #selector(setSafeModeLevel(_:)) { return canChooseSafeModeLevel(menuItem) }
        if action == #selector(requestDisconnect) { return canDisconnect }
        if action == #selector(retryConnection) { return canReconnect }
        return Self.isEnabled(action, context: menuValidationContext(naming: menuItem))
    }

    /// The window's context, with the session a session command acts on taken from the item rather
    /// than from the rail: a menu that lists a connection's sessions names one in each of its items,
    /// and every other route acts on the one the rail has highlighted.
    ///
    /// Keyed on the action rather than on the type in `representedObject`. A conversation row carries
    /// a `UUID` too, and reading that one as a session id resolved a session that does not exist and
    /// wrote its absence over the rail's own highlight, so a conversation row in an open menu decided
    /// what the session commands beside it reported.
    private func menuValidationContext(naming menuItem: NSMenuItem) -> MenuValidationContext {
        var context = menuValidationContext
        guard let action = menuItem.action else { return context }
        if action == #selector(selectNumberedTab(_:)) {
            context.requestedTabNumber = menuItem.tag
        }
        guard Self.agentSessionSelectors.contains(action) else { return context }
        context.agentSessionTarget = agentSessionTarget(for: menuItem)?.status
        return context
    }

    /// The commands whose subject is a session, and the only ones that may read a session id out of
    /// a menu item.
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

    /// Assigning a title or state that has not changed still posts an item-changed notification,
    /// which makes an open menu re-lay-out and cancel tracking. Validation runs on every menu
    /// update, so the writes have to be conditional or the menu bar flickers and a click on an
    /// item dismisses the menu instead of firing it.
    private func applyDynamicTitle(to menuItem: NSMenuItem) {
        guard let action = menuItem.action else { return }
        switch action {
        case #selector(toggleSidebar(_:)):
            setTitle(isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar", on: menuItem)
        /// Both read the surface the pane is drawing, so in Agent mode the pane toggle names the
        /// result column it opens and closes instead of offering to hide an inspector nobody sees.
        case #selector(toggleInspector(_:)):
            setResolvedTitle(TrailingPaneCommandResolver.paneToggleTitle(trailingPaneCommandContext), on: menuItem)
        case #selector(toggleAssistant(_:)):
            setResolvedTitle(TrailingPaneCommandResolver.assistantToggleTitle(trailingPaneCommandContext), on: menuItem)
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
        /// The driver names this one, because what it gives back differs: DuckDB's file lock is
        /// not a server's connection slot. The fallback is what the disabled item reads as for
        /// every connection that holds nothing.
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

    /// The item carries its mode in `representedObject`, so enablement has to see the item rather
    /// than the selector the shared table keys on.
    private func canShowResultView(_ menuItem: NSMenuItem) -> Bool {
        guard let raw = menuItem.representedObject as? String,
              let mode = ResultsViewMode(rawValue: raw) else { return false }
        return commandActions?.availableResultsViewModes.contains(mode) ?? false
    }

    /// Read through the same status the list is built from, so an entry the floor rules out cannot
    /// validate as a choice. The connection's own floor is blind to Agent mode, and asking it enabled
    /// a weaker level the write would then hold at Alert.
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
