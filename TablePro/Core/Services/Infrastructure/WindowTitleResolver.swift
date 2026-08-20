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
struct ResolvedWindowTitle: Equatable {
    let title: String
    let subtitle: String
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
    static func resolveWindow(
        pane: ConnectionWindowPane,
        connection: DatabaseConnection?,
        tab: QueryTab?,
        hasTabs: Bool,
        queryLanguageName: String?
    ) -> ResolvedWindowTitle {
        let connectionName = connection?.name ?? ""

        guard pane == .content else {
            return connectionTitle(connectionName)
        }
        guard hasTabs, let connection else {
            return connectionTitle(connectionName)
        }

        let title = resolveTitle(tab: tab, connection: connection, queryLanguageName: queryLanguageName)
        let subtitle = resolveSubtitle(tab: tab, connection: connection)
        return ResolvedWindowTitle(title: title, subtitle: subtitle == title ? "" : subtitle)
    }

    private static func connectionTitle(_ name: String) -> ResolvedWindowTitle {
        ResolvedWindowTitle(title: name.isBlank ? fallbackTitle : name, subtitle: "")
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

    static func resolveSubtitle(payload: EditorTabPayload?, connection: DatabaseConnection) -> String {
        bindingSubtitle(
            databaseName: payload?.databaseName ?? "",
            schemaName: payload?.schemaName,
            fallback: connection.name
        )
    }

    static func resolveSubtitle(tab: QueryTab?, connection: DatabaseConnection) -> String {
        bindingSubtitle(
            databaseName: tab?.tableContext.databaseName ?? "",
            schemaName: tab?.tableContext.schemaName,
            fallback: connection.name
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

    /// Every tab owns a database for its whole life, so the subtitle names that binding
    /// whatever the tab holds. Only a tab with no binding at all falls back to the
    /// connection, and a blank value counts as no binding at every tier.
    private static func bindingSubtitle(
        databaseName: String,
        schemaName: String?,
        fallback: String
    ) -> String {
        guard !databaseName.isBlank else { return fallback }
        if let schemaName, !schemaName.isBlank {
            return "\(databaseName) · \(schemaName)"
        }
        return databaseName
    }
}
