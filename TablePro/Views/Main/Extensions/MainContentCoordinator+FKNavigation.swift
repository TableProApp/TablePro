//
//  MainContentCoordinator+FKNavigation.swift
//  TablePro
//
//  Foreign key navigation operations for MainContentCoordinator
//

import AppKit
import Foundation
import os

private let fkNavigationLogger = Logger(subsystem: "com.TablePro", category: "FKNavigation")

extension MainContentCoordinator {
    // MARK: - Foreign Key Navigation

    /// Navigate to the referenced table filtered by the FK value.
    /// Opens or switches to the referenced table tab with a pre-applied filter
    /// so only the matching row is shown.
    func navigateToFKReference(value: String, fkInfo: ForeignKeyInfo) {
        let referencedTable = fkInfo.referencedTable
        let referencedColumn = fkInfo.referencedColumn

        fkNavigationLogger.debug("FK navigate: \(referencedTable).\(referencedColumn) = \(value)")

        let filter = TableFilter(
            columnName: referencedColumn,
            filterOperator: .equal,
            value: value
        )

        // Get current database context
        let currentDatabase: String
        if let session = DatabaseManager.shared.session(for: connectionId) {
            currentDatabase = session.activeDatabase
        } else {
            currentDatabase = connection.database
        }

        // Fast path: referenced table is already the active tab — just apply filter
        if let current = tabManager.selectedTab,
           current.tabType == .table,
           current.tableName == referencedTable,
           current.databaseName == currentDatabase {
            applyFKFilter(filter, for: referencedTable)
            // Persist so tab switch restore picks it up
            if let idx = tabManager.selectedTabIndex {
                tabManager.tabs[idx].filterState = filterStateManager.saveToTabState()
            }
            return
        }

        // If current tab has unsaved changes, open in a new native tab instead of replacing
        if changeManager.hasChanges {
            let fkFilterState = TabFilterState(
                filters: [filter],
                appliedFilters: [filter],
                isVisible: true,
                filterLogicMode: .and
            )
            let payload = EditorTabPayload(
                connectionId: connection.id,
                tabType: .table,
                tableName: referencedTable,
                databaseName: currentDatabase,
                isView: false,
                initialFilterState: fkFilterState
            )
            WindowOpener.shared.openNativeTab(payload)
            return
        }

        // Replace current tab content with the referenced table
        let needsQuery = tabManager.replaceTabContent(
            tableName: referencedTable,
            databaseType: connection.type,
            isView: false,
            databaseName: currentDatabase
        )

        if needsQuery, let tabIndex = tabManager.selectedTabIndex {
            tabManager.tabs[tabIndex].pagination.reset()
        }

        // Update editable state for menu items
        if let tabIndex = tabManager.selectedTabIndex {
            let tab = tabManager.tabs[tabIndex]
            AppState.shared.isCurrentTabEditable = tab.isEditable && !tab.isView && tab.tableName != nil
            toolbarState.isTableTab = tab.tabType == .table
            AppState.shared.isTableTab = tab.tabType == .table
        }

        if needsQuery {
            NSApp.keyWindow?.title = referencedTable

            // New tab — build filtered query directly, run once
            guard let tabIndex = tabManager.selectedTabIndex else { return }
            let tab = tabManager.tabs[tabIndex]
            let filteredQuery = queryBuilder.buildFilteredQuery(
                tableName: referencedTable,
                filters: [filter],
                columns: tab.resultColumns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )
            tabManager.tabs[tabIndex].query = filteredQuery

            updateFilterState(filter, for: referencedTable)

            // Persist FK filter to new tab so .onChange → handleTabChange restores it correctly
            tabManager.tabs[tabIndex].filterState = filterStateManager.saveToTabState()

            runQuery()
        } else {
            // Reused tab already has data — apply filter (rebuilds query + re-runs)
            applyFKFilter(filter, for: referencedTable)

            // Persist FK filter to reused tab
            if let tabIndex = tabManager.selectedTabIndex {
                tabManager.tabs[tabIndex].filterState = filterStateManager.saveToTabState()
            }
        }
    }

    private func applyFKFilter(_ filter: TableFilter, for tableName: String) {
        applyFilters([filter])
        updateFilterState(filter, for: tableName)
    }

    private func updateFilterState(_ filter: TableFilter, for tableName: String) {
        filterStateManager.setFKFilter(filter)
    }
}
