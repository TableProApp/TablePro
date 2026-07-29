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
        tableSubtitle(
            isTable: payload?.tabType == .table,
            tableName: payload?.tableName,
            databaseName: payload?.databaseName ?? "",
            schemaName: payload?.schemaName,
            fallback: connection.name
        )
    }

    static func resolveSubtitle(tab: QueryTab?, connection: DatabaseConnection) -> String {
        tableSubtitle(
            isTable: tab?.tabType == .table,
            tableName: tab?.tableContext.tableName,
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

    private static func tableSubtitle(
        isTable: Bool,
        tableName: String?,
        databaseName: String,
        schemaName: String?,
        fallback: String
    ) -> String {
        guard isTable, let tableName, !tableName.isBlank, !databaseName.isBlank else { return fallback }
        if let schemaName, !schemaName.isBlank {
            return "\(databaseName) · \(schemaName)"
        }
        return databaseName
    }
}
