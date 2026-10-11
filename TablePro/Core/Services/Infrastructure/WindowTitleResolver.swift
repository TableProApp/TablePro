//
//  WindowTitleResolver.swift
//  TablePro
//
//  Single source of truth for window and native tab titles.
//

import Foundation

/// Title and subtitle decided together. Resolving them apart is how a window ended up
/// announcing "TablePro - TablePro": two callers each picked the connection name without
/// knowing the other had.
///
/// The proxy icon is decided with them, because it is the rest of what the titlebar says. It
/// used to be written by the browse content alone, which named its own tab's file whatever the
/// window was showing, so a conversation in Agent mode sat under a query file's icon and its
/// Command-click path menu.
struct ResolvedWindowTitle: Equatable {
    let title: String
    let subtitle: String
    let representedURL: URL?

    init(title: String, subtitle: String, representedURL: URL? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.representedURL = representedURL
    }
}

@MainActor
enum WindowTitleResolver {
    static var fallbackTitle: String {
        String(localized: "SQL Query")
    }

    /// The window's name is a function of the pane it is showing, exactly like its content and
    /// its chrome. A window that is not showing content is not showing a document, so naming it
    /// after a tab is naming something that is not there: that is how a connecting window came
    /// to be called "SQL Query", and how a window that lost its session kept the name of the
    /// table it had stopped displaying.
    ///
    /// The same holds for the mode. Agent mode puts a conversation in the detail column and the
    /// editor tabs behind it, so the window names the session it is showing rather than whichever
    /// tab was selected when the mode came on. `agentSessionTitle` is read only then.
    static func resolveWindow(
        pane: ConnectionWindowPane,
        contentMode: ConnectionWorkspaceContentMode,
        agentSessionTitle: String?,
        connection: DatabaseConnection?,
        tab: QueryTab?,
        hasTabs: Bool,
        queryLanguageName: String?
    ) -> ResolvedWindowTitle {
        let connectionName = connection?.name ?? ""

        switch ConnectionWindowPaneResolver.detailMode(for: pane, contentMode: contentMode) {
        case .agent:
            return agentTitle(agentSessionTitle)
        case .browse:
            break
        }

        guard pane == .content else {
            return connectionTitle(connectionName)
        }
        guard hasTabs, let connection else {
            return connectionTitle(connectionName)
        }

        /// No subtitle. The container the window is browsing is the toolbar's centred item, which
        /// is a control that switches it; a subtitle saying the same words is the second copy the
        /// HIG's principal item "takes precedent over". The title names the tab, which is a
        /// different fact and the one a window tab label needs.
        let title = resolveTitle(tab: tab, connection: connection, queryLanguageName: queryLanguageName)
        return ResolvedWindowTitle(title: title, subtitle: "", representedURL: tab?.content.sourceFileURL)
    }

    private static func connectionTitle(_ name: String) -> ResolvedWindowTitle {
        ResolvedWindowTitle(title: name.isBlank ? fallbackTitle : name, subtitle: "")
    }

    /// A session has no name until its first reply or its first question gives it one, and the
    /// window still needs one from the moment the mode comes on, so the mode's own name stands in.
    /// No subtitle, for the reason the tab title carries none: the connection is the toolbar's
    /// centred item. No proxy icon either, since a conversation is not a file, whatever file the
    /// tab behind it was opened from.
    private static func agentTitle(_ sessionTitle: String?) -> ResolvedWindowTitle {
        guard let sessionTitle, !sessionTitle.isBlank else {
            return ResolvedWindowTitle(title: ConnectionWorkspaceContentMode.agent.localizedTitle, subtitle: "")
        }
        return ResolvedWindowTitle(title: sessionTitle, subtitle: "")
    }

    static func resolveTitle(
        payload: EditorTabPayload?,
        databaseType: DatabaseType?,
        queryLanguageName: String?
    ) -> String {
        resolveTitle(
            tabType: payload?.tabType,
            tableName: payload?.tableName,
            schemaName: payload?.schemaName,
            explicitTitle: payload?.tabTitle,
            sourceFileURL: payload?.sourceFileURL,
            databaseType: databaseType,
            queryLanguageName: queryLanguageName
        )
    }

    static func resolveTitle(
        tab: QueryTab?,
        connection: DatabaseConnection,
        queryLanguageName: String?
    ) -> String {
        resolveTitle(
            tabType: tab?.tabType,
            tableName: tab?.tableContext.tableName,
            schemaName: tab?.tableContext.schemaName,
            explicitTitle: tab?.title,
            sourceFileURL: tab?.content.sourceFileURL,
            databaseType: connection.type,
            queryLanguageName: queryLanguageName
        )
    }

    static func sanitizeTitle(previous: String, candidate: String) -> String {
        guard candidate.isBlank else { return candidate }
        return previous.isBlank ? fallbackTitle : previous
    }

    private static func resolveTitle(
        tabType: TabType?,
        tableName: String?,
        schemaName: String?,
        explicitTitle: String?,
        sourceFileURL: URL?,
        databaseType: DatabaseType?,
        queryLanguageName: String?
    ) -> String {
        switch tabType {
        case .serverDashboard:
            return String(localized: "Server Dashboard")
        case .usersRoles:
            return String(localized: "Users & Roles")
        case .insights:
            return String(localized: "Query Insights")
        case .erDiagram:
            return String(localized: "ER Diagram")
        case .createTable:
            return String(localized: "Create Table")
        case .objectSource:
            /// The tab already carries the object's identity as its title. Falling through would
            /// title the window "SQL Query" while its tab reads "Procedure: public.f(date)".
            if let explicitTitle, !explicitTitle.isBlank {
                return explicitTitle
            }
            return String(localized: "Source")
        case .versionHistory:
            if let explicitTitle, !explicitTitle.isBlank {
                return explicitTitle
            }
            return QueryTabManager.versionHistoryFallbackTitle
        default:
            break
        }
        if tabType == .table, let tableName, !tableName.isBlank {
            guard let databaseType else { return tableName }
            return QueryTabManager.tabTitle(name: tableName, schema: schemaName, databaseType: databaseType)
        }
        if let explicitTitle, !explicitTitle.isBlank {
            return explicitTitle
        }
        if let sourceFileURL {
            return QueryTab.fileDisplayTitle(for: sourceFileURL)
        }
        if let queryLanguageName, !queryLanguageName.isBlank {
            return String(format: String(localized: "%@ Query"), queryLanguageName)
        }
        return fallbackTitle
    }
}
