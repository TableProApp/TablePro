//
//  EditorTabOpener.swift
//  TablePro
//

import Foundation
import os

/// Turns an `EditorTabPayload` into a tab. This is the single translation from "what the user
/// asked to open" to "a tab in a connection's list", so a payload opens the same tab whether the
/// connection is being created for it or has been open for hours.
@MainActor
internal enum EditorTabOpener {
    private static let logger = Logger(subsystem: "com.TablePro", category: "EditorTabOpener")

    internal static func apply(
        _ payload: EditorTabPayload,
        to tabManager: QueryTabManager,
        connection: DatabaseConnection,
        toolbarState: ConnectionToolbarState?
    ) {
        let browseDatabaseName = DatabaseManager.shared.browseDatabaseName(for: connection)

        switch payload.intent {
        case .openContent:
            applyContent(
                payload,
                to: tabManager,
                connection: connection,
                toolbarState: toolbarState,
                browseDatabaseName: browseDatabaseName
            )
        case .newEmptyTab:
            let allTabs = MainContentCoordinator.allTabs(for: connection.id)
            tabManager.addTab(
                initialQuery: payload.initialQuery,
                title: QueryTabManager.nextQueryTitle(existingTabs: allTabs),
                databaseName: payload.databaseName ?? browseDatabaseName,
                claimFocus: true
            )
        case .restoreOrDefault:
            break
        }
    }

    private static func applyContent(
        _ payload: EditorTabPayload,
        to tabManager: QueryTabManager,
        connection: DatabaseConnection,
        toolbarState: ConnectionToolbarState?,
        browseDatabaseName: String
    ) {
        switch payload.tabType {
        case .table:
            toolbarState?.isTableTab = true
            applyTable(
                payload,
                to: tabManager,
                connection: connection,
                browseDatabaseName: browseDatabaseName
            )
        case .query:
            let hasContent = payload.initialQuery != nil
                || payload.tabTitle != nil
                || payload.sourceFileURL != nil
            guard hasContent else { return }
            tabManager.addTab(
                initialQuery: payload.initialQuery,
                title: payload.tabTitle,
                databaseName: payload.databaseName ?? browseDatabaseName,
                sourceFileURL: payload.sourceFileURL,
                claimFocus: true
            )
        case .createTable:
            tabManager.addCreateTableTab(databaseName: payload.databaseName ?? browseDatabaseName)
        case .erDiagram:
            tabManager.addERDiagramTab(
                schemaKey: payload.erDiagramSchemaKey ?? payload.databaseName ?? browseDatabaseName,
                databaseName: payload.databaseName ?? browseDatabaseName
            )
        case .serverDashboard:
            tabManager.addServerDashboardTab()
        case .usersRoles:
            tabManager.addUsersRolesTab()
        }
    }

    private static func applyTable(
        _ payload: EditorTabPayload,
        to tabManager: QueryTabManager,
        connection: DatabaseConnection,
        browseDatabaseName: String
    ) {
        let resolvedSchemaName = DatabaseManager.shared.resolvedSchemaName(
            payload.schemaName, for: connection.id
        )

        guard let tableName = payload.tableName else {
            tabManager.addTab(databaseName: payload.databaseName ?? browseDatabaseName)
            return
        }

        do {
            if payload.isPreview {
                try tabManager.addPreviewTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: payload.databaseName ?? browseDatabaseName,
                    schemaName: resolvedSchemaName,
                    isView: payload.isView
                )
            } else {
                try tabManager.addTableTab(
                    tableName: tableName,
                    databaseType: connection.type,
                    databaseName: payload.databaseName ?? browseDatabaseName,
                    schemaName: resolvedSchemaName,
                    isView: payload.isView
                )
            }
        } catch {
            logger.error("create tab for table failed: \(error.localizedDescription, privacy: .public)")
        }

        guard let index = tabManager.selectedTabIndex else { return }
        tabManager.tabs[index].tableContext.isView = payload.isView
        tabManager.tabs[index].tableContext.isEditable = !payload.isView
        tabManager.tabs[index].tableContext.schemaName = resolvedSchemaName
        if payload.showStructure {
            tabManager.tabs[index].display.resultsViewMode = .structure
        }
        if let initialFilter = payload.initialFilterState {
            tabManager.tabs[index].filterState = initialFilter
        }
    }
}
