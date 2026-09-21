//
//  ToolbarContextResolver.swift
//  TablePro
//

import AppKit

/// Which of the connection window's toolbar items a context shows, and which of them answer.
///
/// Two questions with deliberately different inputs, and keeping them apart is what stops the
/// titlebar reflowing while the user types.
///
/// `hidden` is a function of `ToolbarContext.VisibilityKey` alone: the tab kind, the results mode,
/// the content mode and the driver's capabilities. Those change on a tab switch, a mode switch or a
/// connection switch and at no other time, which are the three moments a native app's toolbar is
/// expected to change shape. `isEnabled` carries everything transient, so a staged edit, a running
/// query or a reconnect backoff dims a control and never moves one.
///
/// Version-free on purpose. `NSToolbarItem.isHidden` is macOS 15, and the caller is what decides
/// whether to apply the set or fall back to dimming; the answer itself does not depend on the OS.
///
/// Exhaustive over `TabType` with no `default:` arm. CLAUDE.md's "every switch needs `default:`"
/// rule is about `DatabaseType`, which is an open string-based struct; `TabType` is closed, and a
/// ninth kind must not compile without choosing what its toolbar shows.
internal enum ToolbarContextResolver {
    /// The identifiers this context takes out of the titlebar entirely.
    ///
    /// Only ever names an item from the default set. An item the user dragged in from the
    /// customization palette is opt-in, so it stays where they put it and dims instead; the toolbar
    /// enforces that separately, and a test pins that this set never reaches past the default list.
    ///
    /// Never names both subitems of the centred group at once: measured on macOS 27, hiding both
    /// makes the group vanish while `group.isHidden` stays false, and a popover anchored on it then
    /// lands at the window's centre.
    internal static func hidden(_ context: ToolbarContext) -> Set<NSToolbarItem.Identifier> {
        var hidden: Set<NSToolbarItem.Identifier> = []

        /// A file-based engine has one database and it is the file already named beside it, so the
        /// second capsule has never been clickable on SQLite or DuckDB.
        if context.isFileBased || !context.supportsContainerSwitching {
            hidden.insert(MainWindowToolbar.database)
        }

        switch context.contentMode {
        case .agent:
            /// No grid and no object browser are on screen, and the commit control's gate is frozen
            /// because the browse content tree is not mounted to write it.
            hidden.insert(MainWindowToolbar.refresh)
            hidden.insert(MainWindowToolbar.saveChanges)
            return hidden
        case .browse:
            hidden.formUnion(browseHidden(context))
            return hidden
        }
    }

    private static func browseHidden(_ context: ToolbarContext) -> Set<NSToolbarItem.Identifier> {
        guard let tabKind = context.tabKind else { return [] }
        switch tabKind {
        case .createTable:
            /// A definition that is not on the server yet has nothing to reload.
            return [MainWindowToolbar.refresh]
        case .erDiagram, .serverDashboard, .insights, .objectSource:
            /// None of these four can stage a change, so the commit control could only ever be dim.
            return [MainWindowToolbar.saveChanges]
        case .query, .table, .usersRoles:
            return []
        }
    }

    /// Whether an item answers in this context.
    ///
    /// Every identifier the toolbar vends has an arm. The `default:` returns false rather than true
    /// because the old unconditional arm is what left Query History live and inert over a window
    /// that had never connected, and left every identifier nobody had thought about enabled.
    internal static func isEnabled(
        _ identifier: NSToolbarItem.Identifier,
        context: ToolbarContext
    ) -> Bool {
        switch identifier {
        case MainWindowToolbar.connection, MainWindowToolbar.connectionGroup:
            /// Switch Connection is the window's command, so it answers before a session exists.
            /// It is the route back from a connection that failed.
            return true
        case MainWindowToolbar.database:
            return context.isConnected && !context.isFileBased && context.supportsContainerSwitching
        case MainWindowToolbar.actions:
            /// The menu gates its own entries through the responder chain, so this answers only for
            /// the window having something to be about at all. A closing window opens no menu.
            return context.hasSelectedWorkspace && context.pane != .empty
        case MainWindowToolbar.refresh:
            return context.isConnected && context.contentMode == .browse
        case MainWindowToolbar.saveChanges:
            return context.pendingChange != nil && context.isConnected && !context.blocksAllWrites
        case MainWindowToolbar.safeMode:
            /// Safe Mode is what stands between a stray keystroke and a live table, so it answers
            /// for as long as the session does. A window with no session has nothing to write it to.
            return context.isConnected
        case MainWindowToolbar.inspector:
            /// Not `isConnected`. A connection that drops with the pane open must still be able to
            /// close it, which is the state the old rule disabled on the app's minimum OS.
            return context.canToggleTrailingPane
        case MainWindowToolbar.addRow:
            return context.isConnected && context.canAddRow
        case MainWindowToolbar.restorePreviousValues:
            return context.isConnected && context.canRestorePreviousValues
        case MainWindowToolbar.navigateBack, MainWindowToolbar.backForwardGroup:
            return context.isConnected && context.canNavigateBack
        case MainWindowToolbar.navigateForward:
            return context.isConnected && context.canNavigateForward
        case MainWindowToolbar.previewSQL:
            return context.isConnected && context.hasDataPendingChanges
        case MainWindowToolbar.results:
            /// The results pane belongs to the query editor. The shipped rule was `!isTableTab`,
            /// which enabled it on the five kinds that have no results pane at all and then wrote a
            /// collapse flag with no tab-kind guard behind it.
            return context.isConnected && context.tabKind == .query
        case MainWindowToolbar.history:
            /// The drawer is not mounted in Agent mode, and toggling it there flipped a persisted
            /// flag that sprang the drawer open on the way back to browsing.
            return context.isConnected && context.contentMode == .browse
        case MainWindowToolbar.dashboard:
            return context.isConnected && context.supportsServerDashboard
        case MainWindowToolbar.exportTables, MainWindowToolbar.newTab, MainWindowToolbar.quickSwitcher:
            return context.isConnected
        case MainWindowToolbar.importTables:
            return context.isConnected && !context.blocksAllWrites && context.supportsImport
        case MainWindowToolbar.assistant:
            return context.isConnected && context.isAIEnabled
        default:
            return false
        }
    }

    /// The identifiers `hidden` is allowed to name, which is the default set and nothing else.
    /// Pinned by a test so a later context cannot start hiding a button the user placed.
    internal static let hideableIdentifiers: Set<NSToolbarItem.Identifier> = [
        MainWindowToolbar.database,
        MainWindowToolbar.refresh,
        MainWindowToolbar.saveChanges,
    ]
}
