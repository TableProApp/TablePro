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
    func navigateToFKReference(value: String, fkInfo: ForeignKeyInfo, openInNewTab: Bool) {
        let referencedTable = fkInfo.referencedTable
        let referencedColumn = fkInfo.referencedColumn

        fkNavigationLogger.debug("FK navigate: \(referencedTable).\(referencedColumn) = \(value) newTab=\(openInNewTab)")

        let filter = TableFilter(
            columnName: referencedColumn,
            filterOperator: .equal,
            value: value
        )

        let currentDatabase = activeDatabaseName

        let targetSchema = fkInfo.referencedSchema ?? DatabaseManager.shared.session(for: connectionId)?.currentSchema

        if !openInNewTab,
           let current = tabManager.selectedTab,
           current.tabType == .table,
           current.tableContext.tableName == referencedTable,
           current.tableContext.databaseName == currentDatabase,
           current.tableContext.schemaName == targetSchema {
            applyFKFilter(filter, for: referencedTable)
            return
        }

        if openInNewTab || changeManager.hasChanges {
            let payload = makeFKReferencePayload(
                filter: filter,
                referencedTable: referencedTable,
                databaseName: currentDatabase,
                schemaName: targetSchema
            )
            WindowManager.shared.openTab(payload: payload)
            return
        }

        let needsQuery: Bool
        do {
            needsQuery = try tabManager.replaceTabContent(
                tableName: referencedTable,
                databaseType: connection.type,
                isView: false,
                databaseName: currentDatabase,
                schemaName: targetSchema
            )
        } catch {
            fkNavigationLogger.error("navigateToFKReference replaceTabContent failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        if needsQuery, let (tab, tabIndex) = tabManager.selectedTabAndIndex {
            setActiveTableRows(TableRows(), for: tab.id)
            tabManager.mutate(at: tabIndex) { $0.pagination.reset() }
        }

        if let (tab, _) = tabManager.selectedTabAndIndex {
            toolbarState.isTableTab = tab.tabType == .table
        }

        if needsQuery {
            NSApp.keyWindow?.title = referencedTable

            guard let (tab, tabIndex) = tabManager.selectedTabAndIndex else { return }
            let tableRows = tabSessionRegistry.tableRows(for: tab.id)
            let filteredQuery = queryBuilder.buildFilteredQuery(
                tableName: referencedTable,
                schemaName: targetSchema,
                filters: [filter],
                columns: tableRows.columns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )
            tabManager.mutate(at: tabIndex) { $0.content.query = filteredQuery }

            updateFilterState(filter, for: referencedTable)

            runQuery()
        } else {
            applyFKFilter(filter, for: referencedTable)
        }
    }

    func makeFKReferencePayload(
        filter: TableFilter,
        referencedTable: String,
        databaseName: String?,
        schemaName: String?
    ) -> EditorTabPayload {
        let fkFilterState = TabFilterState(
            filters: [filter],
            commit: .all,
            isVisible: true,
            filterLogicMode: .and
        )
        return EditorTabPayload(
            connectionId: connection.id,
            tabType: .table,
            tableName: referencedTable,
            databaseName: databaseName,
            schemaName: schemaName,
            isView: false,
            initialFilterState: fkFilterState
        )
    }

    /// Toggle FK preview for the currently focused cell in the data grid.
    /// Called from the menu command system (Settings > Keyboard rebindable).
    func toggleFKPreviewForFocusedCell() {
        guard let tableView = NSApp.keyWindow?.firstResponder as? KeyHandlingTableView,
              let coordinator = tableView.coordinator,
              tableView.selectedRow >= 0,
              tableView.focusedColumn >= 1
        else { return }
        coordinator.toggleForeignKeyPreview(
            tableView: tableView,
            row: tableView.selectedRow,
            column: tableView.focusedColumn,
            columnIndex: tableView.focusedColumn - 1
        )
    }

    private func applyFKFilter(_ filter: TableFilter, for tableName: String) {
        applyFilters([filter])
        updateFilterState(filter, for: tableName)
    }

    private func updateFilterState(_ filter: TableFilter, for tableName: String) {
        setFKFilter(filter)
    }
}
