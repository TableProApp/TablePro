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
/// `visibility(for:)` and `commitVerb(for:)` take `ToolbarContext.VisibilityKey` or a part of it and
/// nothing else, so the type says what the shape may depend on: the tab kind, the results mode, the
/// content mode and the driver's capabilities. Those change on a tab switch, a mode switch or a
/// connection switch and at no other time, which are the three moments a native app's toolbar is
/// expected to change shape. `isEnabled` carries everything transient, so a staged edit, a running
/// query or a reconnect backoff dims a control and never moves or relabels one.
///
/// Version-free on purpose. `NSToolbarItem.isHidden` is macOS 15, and the caller is what decides
/// whether to apply the set or fall back to dimming; the answer itself does not depend on the OS.
///
/// Exhaustive over `TabType` with no `default:` arm. CLAUDE.md's "every switch needs `default:`"
/// rule is about `DatabaseType`, which is an open string-based struct; `TabType` is closed, and a
/// ninth kind must not compile without choosing what its toolbar shows.
internal enum ToolbarContextResolver {
    /// The identifiers the app may take out of the titlebar, which is exactly the set it puts there.
    ///
    /// Derived rather than listed, so the rule cannot drift from the toolbar: an item is hideable
    /// because the app placed it, and anything else in `NSToolbar.items` was dragged in from the
    /// customization palette by the user. That item is opt-in, so it stays where they put it in every
    /// context and only dims. Measured on macOS 27 with two palette items inserted into a live
    /// toolbar, a pass that hid through this filter wrote neither of them and moved neither.
    ///
    /// The spaces and tracking separators are in it, and deliberately so. Filtering the standard
    /// identifiers out by their `NSToolbar` prefix would also declare the sidebar and inspector
    /// toggles unhideable, and a space only ever receives `isHidden = false`, which AppKit returns
    /// from early at about 2.5ns a write.
    internal static let hideableIdentifiers = Set(MainWindowToolbar.defaultItemIdentifiers)

    /// What this context takes out of the titlebar, already confined to what may be taken.
    ///
    /// The confinement lives here rather than at the call site, so it is a property of the answer
    /// and a second caller cannot skip it.
    internal static func visibility(for key: ToolbarContext.VisibilityKey) -> ToolbarVisibility {
        ToolbarVisibility(hidden: contextualHidden(key).intersection(hideableIdentifiers))
    }

    /// The commit control's label: the verb its tab commits with.
    ///
    /// Keyed on the tab kind and never on what is staged. The staged change moves with every edit:
    /// a Create Table draft is `.createTable` only while it validates, so a label read from it
    /// flipped between Save Changes and Create Table as the user typed, and with labels shown each
    /// flip changed the item's width and reflowed the titlebar. The kind moves on a tab switch,
    /// when the item set may change anyway. Nothing staged still leaves the control dim, which is
    /// `isEnabled`'s answer.
    internal static func commitVerb(for tabKind: TabType?) -> String {
        switch tabKind {
        case .createTable:
            String(localized: "Create Table")
        case .usersRoles:
            String(localized: "Apply Changes")
        case .query, .table, .erDiagram, .serverDashboard, .insights, .objectSource, nil:
            String(localized: "Save Changes")
        }
    }

    private static func contextualHidden(_ key: ToolbarContext.VisibilityKey) -> Set<NSToolbarItem.Identifier> {
        var hidden: Set<NSToolbarItem.Identifier> = []

        /// A file-based engine has one database and it is the file already named beside it, so the
        /// second capsule has never been clickable on SQLite or DuckDB.
        if key.isFileBased || !key.supportsContainerSwitching {
            hidden.insert(MainWindowToolbar.database)
        }

        switch key.contentMode {
        case .agent:
            /// No grid and no object browser are on screen, and the commit control's gate is frozen
            /// because the browse content tree is not mounted to write it.
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
    /// Every command the toolbar vends has an arm. The Back and Forward group has none because it is
    /// a container: it carries no action, so AppKit never asks for it, and each of its two subitems
    /// answers for itself. The `default:` returns false rather than true because the old
    /// unconditional arm is what left Query History live and inert over a window that had never
    /// connected, and left every identifier nobody had thought about enabled.
    internal static func isEnabled(
        _ identifier: NSToolbarItem.Identifier,
        context: ToolbarContext
    ) -> Bool {
        switch identifier {
        case MainWindowToolbar.connection:
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
        case MainWindowToolbar.navigateBack:
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
            /// The View menu's Show Assistant, read from the same answer rather than rebuilt here.
            /// Agent mode dims it, because the mode draws the conversation as the content column and
            /// the result in the pane, and a connection that drops with the assistant open still lets
            /// it close, as the inspector's button does.
            return context.canToggleAssistant
        default:
            return false
        }
    }
}
