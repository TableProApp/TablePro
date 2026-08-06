//
//  WindowTitleResolver.swift
//  TablePro
//
//  Single source of truth for window and native tab titles.
//

import Foundation

@MainActor
enum WindowTitleResolver {
    static var fallbackTitle: String {
        String(localized: "SQL Query")
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
