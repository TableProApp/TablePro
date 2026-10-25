//
//  MainContentCoordinator+NavigationHistory.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProPluginKit

private let navigationHistoryLogger = Logger(subsystem: "com.TablePro", category: "NavigationHistory")

extension MainContentCoordinator {
    // MARK: - Availability

    // Unsaved cell edits do not refuse Back: `step(back:)` goes through the discard alert; refusing left Back dim with no reason.
    var canNavigateBack: Bool {
        guard let tabId = navigableTabId else { return false }
        return navigationHistories[tabId]?.canGoBack ?? false
    }

    var canNavigateForward: Bool {
        guard let tabId = navigableTabId else { return false }
        return navigationHistories[tabId]?.canGoForward ?? false
    }

    private var navigableTabId: UUID? {
        guard let tab = tabManager.selectedTab,
              tab.tabType == .table,
              !selectedTabBlocksNavigation else { return nil }
        return tab.id
    }

    // Staged structure edits block: the discard alert clears only `changeManager`, so offering to discard them is a broken promise.
    private var selectedTabBlocksNavigation: Bool {
        guard let tab = tabManager.selectedTab else { return true }
        return hasStagedStructureEdits(in: tab)
    }

    // MARK: - Recording

    // Capture and commit are separate because a retarget can fail; recording a non-move dupes Back and drops the forward stack.
    func captureNavigationEntry() -> TabNavigationEntry? {
        guard let tab = tabManager.selectedTab,
              tab.tabType == .table,
              let tableName = tab.tableContext.tableName,
              !tableName.isEmpty else { return nil }

        return TabNavigationEntry(
            tableName: tableName,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName,
            isView: tab.tableContext.isView,
            objectType: tab.tableContext.objectType,
            resultsViewMode: tab.display.resultsViewMode,
            filterState: tab.filterState,
            sortColumns: tab.sortState.persistedColumns,
            sortSource: tab.sortState.source,
            page: tab.pagination.currentPage,
            pageSize: tab.pagination.pageSize,
            anchorRowKey: capturePrimaryKeyAnchor(for: tab),
            isTemporary: tab.tableContext.isTemporary
        )
    }

    // Only in-place retargets record; a jump that opens its own tab leaves the source open and starts with an empty history.
    func commitNavigationEntry(_ entry: TabNavigationEntry?) {
        guard let entry, let tabId = tabManager.selectedTabId else { return }
        navigationHistories[tabId, default: TabNavigationHistory()].record(entry)
    }

    // The key of the row the reader is on, so returning lands on that row rather than at the top (#1837).
    private func capturePrimaryKeyAnchor(for tab: QueryTab) -> [String: String]? {
        let keyColumns = tab.tableContext.primaryKeyColumns
        guard !keyColumns.isEmpty,
              let model = existingGridModel(forTab: tab.id),
              let displayIndex = model.selection.affectedRows.first,
              let row = model.row(at: displayIndex) else { return nil }

        let tableRows = model.rows

        return NavigationRowAnchor.build(
            keyColumns: keyColumns,
            columns: tableRows.columns,
            values: row.values,
            isModified: { column in
                changeManager.isCellModified(rowID: row.id, columnIndex: column)
            }
        )
    }

    // MARK: - Navigating

    func navigateBack() {
        step(back: true)
    }

    func navigateForward() {
        step(back: false)
    }

    // Captures before the discard guard: discarding keeps edited values in `TableRows`, so a later capture anchors on dropped keys.
    private func step(back: Bool) {
        let departing = captureNavigationEntry()
        confirmDiscardChangesIfNeeded(action: .navigation) { [weak self] confirmed in
            guard confirmed else { return }
            self?.commitStep(back: back, from: departing)
        }
    }

    // Stacks change on a copy, written back only once the restore lands, so a failed retarget leaves the history untouched.
    private func commitStep(back: Bool, from departing: TabNavigationEntry?) {
        guard let tabId = navigableTabId,
              var history = navigationHistories[tabId],
              let current = departing else { return }
        guard let entry = back ? history.stepBack(from: current) : history.stepForward(from: current) else {
            return
        }

        guard restore(entry, in: tabId) else {
            navigationHistoryLogger.error("navigation restore failed, history left untouched")
            return
        }
        navigationHistories[tabId] = history
        navigationHistoryLogger.debug("navigated to \(entry.tableName, privacy: .public)")
    }

    // Follows `reuseActiveTab`'s sequence, but loads the recorded filters, sort and page instead of the table's saved defaults.
    private func restore(_ entry: TabNavigationEntry, in tabId: UUID) -> Bool {
        do {
            try tabManager.replaceTabContent(
                tableName: entry.tableName,
                databaseType: connection.type,
                isView: entry.isView,
                objectType: entry.objectType,
                isTemporary: entry.isTemporary,
                databaseName: entry.databaseName,
                schemaName: entry.schemaName
            )
        } catch {
            navigationHistoryLogger.error(
                "restore replaceTabContent failed: \(error.publicLogShape, privacy: .public)"
            )
            return false
        }

        discardRowsForRetarget(resultsViewMode: entry.resultsViewMode)
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex, tab.id == tabId else { return false }

        // Always carry the page: `replaceTabContent` resets to the default page size, so a recorded page would come back resized.
        tabManager.mutate(at: tabIndex) { tab in
            tab.filterState = entry.filterState
            tab.pendingRestoredSort = entry.sortColumns.isEmpty ? nil : entry.sortColumns
            tab.restoredSortSource = entry.sortSource
            if entry.sortColumns.isEmpty {
                tab.sortState = SortState(columns: [], source: entry.sortSource)
            }
            tab.restoredPage = max(1, entry.page)
            tab.restoredPageSize = entry.pageSize
            tab.restoredRowAnchor = entry.anchorRowKey
        }

        restoreLastHiddenColumnsForTable()
        filterCoordinator.rebuildTableQuery(at: tabIndex)
        cancelTableLoad(for: tabId)
        lazyLoadCurrentTabIfNeeded()
        return true
    }
}
