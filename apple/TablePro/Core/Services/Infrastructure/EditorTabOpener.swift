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
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "EditorTabOpener")

    internal static func apply(
        _ payload: EditorTabPayload,
        to tabManager: QueryTabManager,
        connection: DatabaseConnection,
        toolbarState: ConnectionToolbarState?
    ) {
        let browseDatabaseName = DatabaseManager.shared.browseDatabaseName(for: connection)
        /// A table named without a database is the one in the database being browsed, the same answer
        /// the lookup for a tab already showing it gives. Anything else opened without one belongs to
        /// the entry on screen, which the cursor lags while a switch to it is on its way.
        let openingDatabaseName = tabManager.openingDatabase(browsing: browseDatabaseName)

        switch payload.intent {
        case .openContent:
            applyContent(
                payload,
                to: tabManager,
                connection: connection,
                toolbarState: toolbarState,
                browseDatabaseName: browseDatabaseName,
                openingDatabaseName: openingDatabaseName
            )
        case .newEmptyTab:
            let allTabs = MainContentCoordinator.allTabs(for: connection.id)
            tabManager.addTab(
                initialQuery: payload.initialQuery,
                title: QueryTabManager.nextQueryTitle(existingTabs: allTabs),
                databaseName: payload.databaseName ?? openingDatabaseName,
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
        browseDatabaseName: String,
        openingDatabaseName: String
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
                databaseName: payload.databaseName ?? openingDatabaseName,
                sourceFileURL: payload.sourceFileURL,
                sourceFileStamp: payload.sourceFileStamp,
                sourceFileEncoding: payload.sourceFileEncoding,
                claimFocus: true
            )
        case .createTable:
            tabManager.addCreateTableTab(
                databaseName: payload.databaseName ?? openingDatabaseName,
                schemaName: payload.schemaName
            )
        case .erDiagram:
            tabManager.addERDiagramTab(
                schemaKey: payload.erDiagramSchemaKey ?? payload.databaseName ?? openingDatabaseName,
                databaseName: payload.databaseName ?? openingDatabaseName,
                schemaName: payload.schemaName
            )
        case .serverDashboard:
            tabManager.addServerDashboardTab()
        case .usersRoles:
            tabManager.addUsersRolesTab()
        case .insights:
            tabManager.addQueryInsightsTab()
        case .objectSource:
            guard let objectRef = payload.objectRef else { return }
            tabManager.addObjectSourceTab(objectRef: objectRef)
        case .versionHistory:
            guard let subject = payload.versionHistorySubject else { return }
            tabManager.addVersionHistoryTab(subject: subject, title: payload.tabTitle ?? QueryTabManager.versionHistoryFallbackTitle)
        case .tableListing:
            tabManager.addTableListingTab(
                title: payload.tabTitle ?? String(localized: "Tables"),
                databaseName: payload.databaseName ?? openingDatabaseName,
                schemaName: payload.schemaName
            )
        case .routineDebug:
            // A payload cannot carry a live session; the coordinator opens debug tabs itself.
            return
        }
    }

    private static func applyTable(
        _ payload: EditorTabPayload,
        to tabManager: QueryTabManager,
        connection: DatabaseConnection,
        browseDatabaseName: String
    ) {
        let databaseName = payload.databaseName ?? browseDatabaseName
        let resolvedSchemaName = DatabaseManager.shared.resolvedSchemaName(
            payload.schemaName, inDatabase: databaseName, for: connection.id
        )

        guard let tableName = payload.tableName else {
            tabManager.addTab(databaseName: databaseName)
            return
        }

        let didCreateTab: Bool
        do {
            didCreateTab = try tabManager.addTableTab(
                tableName: tableName,
                databaseType: connection.type,
                databaseName: databaseName,
                schemaName: resolvedSchemaName,
                isView: payload.isView,
                objectType: payload.objectType,
                isTemporary: payload.isTemporary,
                isPreview: payload.isPreview,
                allowsDuplicate: payload.forcesNewTab
            )
        } catch {
            logger.error("create tab for table failed: \(error.publicLogShape, privacy: .public)")
            return
        }

        /// Only a tab this payload created may take the payload's state. An existing tab was
        /// reselected, not asked for, and writing the payload's filter over its own would destroy
        /// work the user did there while leaving the grid on rows the new filter never ran.
        guard didCreateTab, let index = tabManager.selectedTabIndex else { return }
        tabManager.tabs[index].tableContext.isView = payload.isView
        tabManager.tabs[index].tableContext.objectType = payload.objectType
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
