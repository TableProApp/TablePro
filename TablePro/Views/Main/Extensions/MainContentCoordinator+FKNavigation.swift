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
    /// Reuses the current tab when it holds nothing the user authored, and otherwise opens the
    /// reference in its own tab so the originating query or edits survive.
    func navigateToFKReference(value: String, fkInfo: ForeignKeyInfo, openInNewTab: Bool) {
        let referencedTable = fkInfo.referencedTable
        let referencedColumn = fkInfo.referencedColumn

        fkNavigationLogger.debug("FK navigate: \(referencedTable).\(referencedColumn) = \(value) newTab=\(openInNewTab)")

        let filter = TableFilter(
            columnName: referencedColumn,
            filterOperator: .equal,
            value: value
        )

        guard let sourceScope = selectedTabScope else {
            fkNavigationLogger.error("FK navigate skipped: the source tab is not bound to a database")
            return
        }

        let currentDatabase = sourceScope.database
        let targetSchema = fkInfo.referencedSchema.flatMap { $0.isEmpty ? nil : $0 } ?? sourceScope.schema

        if !openInNewTab,
           let current = tabManager.selectedTab,
           matchesFKTarget(current, table: referencedTable, database: currentDatabase, schema: targetSchema) {
            applyFKFilter(filter, for: referencedTable)
            return
        }

        guard openInNewTab || selectedTabHoldsProtectedContent else {
            replaceSelectedTabWithFKTarget(
                referencedTable: referencedTable,
                filter: filter,
                databaseName: currentDatabase,
                schemaName: targetSchema
            )
            return
        }

        if !openInNewTab,
           let existing = openFKTargetTab(
               table: referencedTable,
               database: currentDatabase,
               schema: targetSchema,
               filter: filter
           ) {
            existing.coordinator.selectTabAndFocusWindow(existing.tabId)
            return
        }

        promotePreviewTab()
        let payload = makeFKReferencePayload(
            filter: filter,
            referencedTable: referencedTable,
            databaseName: currentDatabase,
            schemaName: targetSchema
        )
        openTabInNewWindow(payload)
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
        /// This payload is only built once no open tab could take the jump, so it must land in a
        /// tab of its own. Reusing one would write the FK filter over filters the user applied
        /// there, and leave the grid on rows the new filter never ran against.
        return EditorTabPayload(
            connectionId: connection.id,
            tabType: .table,
            tableName: referencedTable,
            databaseName: databaseName,
            schemaName: schemaName,
            isView: false,
            forcesNewTab: true,
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

    private func matchesFKTarget(_ tab: QueryTab, table: String, database: String, schema: String?) -> Bool {
        tab.tabType == .table
            && tab.tableContext.tableName == table
            && tab.tableContext.databaseName == database
            && tab.tableContext.schemaName == schema
    }

    private func isSameFKPredicate(_ lhs: TableFilter, _ rhs: TableFilter) -> Bool {
        lhs.columnName == rhs.columnName
            && lhs.filterOperator == rhs.filterOperator
            && lhs.value == rhs.value
    }

    /// A tab already showing exactly this reference. Matching the filter too keeps a click on a
    /// different row from re-filtering a tab the user opened for another one.
    private func openFKTargetTab(
        table: String,
        database: String,
        schema: String?,
        filter: TableFilter
    ) -> (coordinator: MainContentCoordinator, tabId: UUID)? {
        func matches(_ tab: QueryTab) -> Bool {
            guard matchesFKTarget(tab, table: table, database: database, schema: schema) else { return false }
            let applied = tab.filterState.appliedFilters
            guard applied.count == 1 else { return false }
            return isSameFKPredicate(applied[0], filter)
        }

        if let match = tabManager.tabs.first(where: matches) {
            return (self, match.id)
        }

        for sibling in MainContentCoordinator.allActiveCoordinators()
            where sibling !== self && sibling.connectionId == connectionId {
            guard let match = sibling.tabManager.tabs.first(where: matches) else { continue }
            return (sibling, match.id)
        }
        return nil
    }

    private func replaceSelectedTabWithFKTarget(
        referencedTable: String,
        filter: TableFilter,
        databaseName: String,
        schemaName: String?
    ) {
        if let outgoingTable = tabManager.selectedTab?.tableContext.tableName {
            saveLastFilters(for: outgoingTable)
        }

        let replaced: Bool
        do {
            replaced = try tabManager.replaceTabContent(
                tableName: referencedTable,
                databaseType: connection.type,
                isView: false,
                databaseName: databaseName,
                schemaName: schemaName
            )
        } catch {
            fkNavigationLogger.error("navigateToFKReference replaceTabContent failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard replaced, let (replacedTab, tabIndex) = tabManager.selectedTabAndIndex else {
            applyFKFilter(filter, for: referencedTable)
            return
        }

        let tabId = replacedTab.id
        cancelTableLoad(for: tabId)
        toolbarState.isTableTab = true
        setActiveTableRows(TableRows(), for: tabId)
        tabManager.mutate(at: tabIndex) { $0.pagination.reset() }
        restoreLastHiddenColumnsForTable()

        guard let pagination = tabManager.selectedTab?.pagination else { return }
        let tableRows = tabSessionRegistry.tableRows(for: tabId)
        let filteredQuery = queryBuilder.buildFilteredQuery(
            tableName: referencedTable,
            schemaName: schemaName,
            filters: [filter],
            columns: tableRows.columns,
            columnTypes: tableRows.columnTypes,
            limit: pagination.pageSize,
            offset: pagination.currentOffset
        )
        tabManager.mutate(at: tabIndex) { $0.content.query = filteredQuery }

        updateFilterState(filter, for: referencedTable)

        runQuery()
    }

    private func applyFKFilter(_ filter: TableFilter, for tableName: String) {
        applyFilters([filter])
        updateFilterState(filter, for: tableName)
    }

    private func updateFilterState(_ filter: TableFilter, for tableName: String) {
        setFKFilter(filter)
    }
}
