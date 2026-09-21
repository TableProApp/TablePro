//
//  ConnectionActionsMenuResolver.swift
//  TablePro
//

import AppKit

/// What the Actions pull-down offers in a context.
///
/// This is where the commands that used to each own a permanent slot in the titlebar now live. One
/// control whose menu changes, rather than seventeen buttons of which most are dim on most tabs.
///
/// Every entry has a menu-bar twin carrying the same title, and that is a rule rather than a
/// coincidence: a pull-down that grows commands of its own becomes a second, undiscoverable menu
/// bar. A test pins it.
///
/// Nothing here reads a global. What the driver supports, what the tab is and what the window is
/// doing all arrive in the context, so the whole table is decided by a value and testable without a
/// session.
internal enum ConnectionActionsMenuResolver {
    internal static func sections(_ context: ToolbarContext) -> [ActionsMenuSection] {
        switch context.contentMode {
        case .agent:
            return [modeSection(context), connectionSection(context)].compactMap(\.self)
        case .browse:
            return browseSections(context)
        }
    }

    private static func browseSections(_ context: ToolbarContext) -> [ActionsMenuSection] {
        guard context.isConnected else {
            return [modeSection(context), connectionSection(context)].compactMap(\.self)
        }
        return [
            rowSection(context),
            historySection(context),
            dataSection(context),
            objectSection(context),
            windowSection(context),
            editorSection(context),
            modeSection(context),
            connectionSection(context),
        ].compactMap(\.self)
    }

    // MARK: - Sections

    /// The commands that act on the rows in front of the user. Add Row asks the same question the
    /// grid does, so it follows the results mode rather than the tab kind alone.
    private static func rowSection(_ context: ToolbarContext) -> ActionsMenuSection? {
        var entries: [ActionsMenuEntry] = []
        if context.tabKind == .table, context.resultsMode == .data {
            entries.append(
                ActionsMenuEntry(
                    title: String(localized: "Add Row"),
                    selector: NSSelectorFromString("addRow:"),
                    shortcut: .addRow
                )
            )
        }
        if context.tabKind == .table || context.tabKind == .query {
            entries.append(
                ActionsMenuEntry(
                    title: String(localized: "Restore Previous Values…"),
                    selector: NSSelectorFromString("restorePreviousValues:")
                )
            )
        }
        return entries.isEmpty ? nil : ActionsMenuSection(entries)
    }

    /// Back and Forward walk a table's own browse history, which only a table tab has.
    private static func historySection(_ context: ToolbarContext) -> ActionsMenuSection? {
        guard context.tabKind == .table else { return nil }
        return ActionsMenuSection([
            ActionsMenuEntry(
                title: String(localized: "Back"),
                selector: NSSelectorFromString("navigateBack:"),
                shortcut: .navigateBack
            ),
            ActionsMenuEntry(
                title: String(localized: "Forward"),
                selector: NSSelectorFromString("navigateForward:"),
                shortcut: .navigateForward
            ),
        ])
    }

    /// What goes in and what comes out. Preview SQL sits beside the commit verb's own tabs because
    /// it answers the question the commit raises.
    private static func dataSection(_ context: ToolbarContext) -> ActionsMenuSection? {
        var entries: [ActionsMenuEntry] = []
        if context.tabKind == .table || context.tabKind == .query || context.tabKind == .createTable {
            entries.append(
                ActionsMenuEntry(
                    title: String(localized: "Preview SQL"),
                    selector: NSSelectorFromString("previewSQL:"),
                    shortcut: .previewSQL
                )
            )
        }
        if context.tabKind == .query {
            /// The one context with a results pane to collapse. The shipped rule offered this on
            /// the five kinds that have none.
            entries.append(
                ActionsMenuEntry(
                    title: String(localized: "Show Results"),
                    selector: NSSelectorFromString("toggleResults:"),
                    shortcut: .toggleResults
                )
            )
        }
        if context.tabKind == .table || context.tabKind == .query {
            entries.append(
                ActionsMenuEntry(
                    title: String(localized: "Export Results…"),
                    selector: NSSelectorFromString("exportQueryResults:")
                )
            )
        }
        entries.append(
            ActionsMenuEntry(
                title: String(localized: "Export Tables…"),
                selector: NSSelectorFromString("exportTables:"),
                shortcut: .export
            )
        )
        if context.supportsImport {
            /// The command and the format list are two rows, as they are under File > Import. The
            /// leaf is the one ⇧⌘I runs and says so, and it takes the driver's first format; a row
            /// that owns a submenu can carry neither the action nor the chord. The list is how any
            /// other format is reached, filled when it opens.
            ///
            /// Gated on the driver's capability, which is a registry read, and not on the formats it
            /// actually has: counting those activates every lazily loaded import plugin, and retries
            /// the load gate of one that failed it, on every ask. The window's validation answers
            /// the rest, dimming the leaf when there is nothing to import, and the list says so in
            /// its own placeholder.
            entries.append(
                ActionsMenuEntry(
                    title: String(localized: "Import Data…"),
                    selector: NSSelectorFromString("importData:"),
                    shortcut: .importData
                )
            )
            entries.append(
                ActionsMenuEntry(title: String(localized: "Import Data From"), submenu: .importFormats)
            )
        }
        return entries.isEmpty ? nil : ActionsMenuSection(entries)
    }

    /// What the selected object is made of.
    private static func objectSection(_ context: ToolbarContext) -> ActionsMenuSection? {
        guard context.tabKind == .table || context.tabKind == .objectSource else { return nil }
        return ActionsMenuSection([
            ActionsMenuEntry(
                title: String(localized: "Show DDL"),
                selector: NSSelectorFromString("showObjectDDL:")
            ),
            ActionsMenuEntry(
                title: String(localized: "Copy DDL"),
                selector: NSSelectorFromString("copyObjectDDL:")
            ),
        ])
    }

    /// The places in this connection the window can go. Each of these opens a tab or a drawer, so
    /// they belong together and away from the commands that change data.
    private static func windowSection(_ context: ToolbarContext) -> ActionsMenuSection? {
        var entries: [ActionsMenuEntry] = [
            ActionsMenuEntry(
                title: String(localized: "Show Query History"),
                selector: NSSelectorFromString("toggleQueryHistory:"),
                shortcut: .toggleHistory
            ),
            ActionsMenuEntry(
                title: String(localized: "Users & Roles"),
                selector: NSSelectorFromString("showUsersAndRoles:")
            ),
            ActionsMenuEntry(
                title: String(localized: "Query Insights"),
                selector: NSSelectorFromString("showQueryInsights:")
            ),
        ]
        if context.supportsServerDashboard {
            entries.append(
                ActionsMenuEntry(
                    title: String(localized: "Server Dashboard"),
                    selector: NSSelectorFromString("showServerDashboard:")
                )
            )
        }
        return ActionsMenuSection(entries)
    }

    private static func editorSection(_ context: ToolbarContext) -> ActionsMenuSection? {
        ActionsMenuSection([
            ActionsMenuEntry(
                title: String(localized: "New Tab"),
                selector: NSSelectorFromString("newEditorTab:"),
                shortcut: .newTab
            ),
            ActionsMenuEntry(
                title: String(localized: "Open Quickly…"),
                selector: NSSelectorFromString("openQuickSwitcher:"),
                shortcut: .quickSwitcher
            ),
        ])
    }

    /// The mode control's new home, now that it no longer holds two permanent segments in the
    /// titlebar. Absent with AI off, where Agent mode does not exist.
    private static func modeSection(_ context: ToolbarContext) -> ActionsMenuSection? {
        guard context.isAIEnabled else { return nil }
        return ActionsMenuSection([
            ActionsMenuEntry(title: String(localized: "Mode"), submenu: .mode),
        ])
    }

    /// The route out of a window whose connection went away, and the reason the pull-down answers
    /// in every phase rather than only over a live session.
    private static func connectionSection(_ context: ToolbarContext) -> ActionsMenuSection? {
        var entries: [ActionsMenuEntry] = [
            ActionsMenuEntry(
                title: String(localized: "Switch Connection…"),
                selector: NSSelectorFromString("switchConnection:"),
                shortcut: .switchConnection
            ),
        ]
        if !context.isConnected {
            /// Declared with no sender, and the menu bar spells it the same way. A selector with a
            /// colon reaches nothing and AppKit draws the entry disabled.
            entries.append(
                ActionsMenuEntry(
                    title: String(localized: "Reconnect"),
                    selector: NSSelectorFromString("retryConnection")
                )
            )
        }
        entries.append(
            ActionsMenuEntry(
                title: String(localized: "Close Connection"),
                selector: NSSelectorFromString("closeConnection:")
            )
        )
        return ActionsMenuSection(entries)
    }
}
