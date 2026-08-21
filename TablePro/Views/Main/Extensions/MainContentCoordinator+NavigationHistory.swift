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

    /// Back is refused while the tab holds work that lives nowhere else, for the same reason a
    /// retarget is: going back replaces the tab's content, and unsaved edits would go with it.
    ///
    /// It is also refused once the tab is showing something other than a table, because stepping
    /// back would have nothing to put on the forward stack in its place.
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
              !selectedTabHoldsProtectedContent else { return nil }
        return tab.id
    }

    // MARK: - Recording

    /// What the selected tab is showing right now, or nil when it is not showing a table.
    ///
    /// Capturing and recording are two calls rather than one because a retarget can fail. Recording
    /// what a tab was showing when it never left would push a duplicate onto Back and, worse, drop
    /// the whole forward stack for a navigation that did not happen.
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
            resultsViewMode: tab.display.resultsViewMode,
            filterState: tab.filterState,
            sortColumns: tab.sortState.persistedColumns,
            page: tab.pagination.currentPage,
            pageSize: tab.pagination.pageSize,
            anchorRowKey: capturePrimaryKeyAnchor(for: tab)
        )
    }

    /// Records a location the selected tab has now left, once the retarget that left it succeeded.
    ///
    /// Every navigation that retargets a tab in place calls this, because those are the only ones
    /// that overwrite a view the reader has no other route back to. A jump that opens its own tab
    /// records nothing: the tab it came from is still open, and the new tab starts with an empty
    /// history, the way Command-clicking a link does.
    func commitNavigationEntry(_ entry: TabNavigationEntry?) {
        guard let entry, let tabId = tabManager.selectedTabId else { return }
        navigationHistories[tabId, default: TabNavigationHistory()].record(entry)
    }

    /// The primary-key values of the row the reader is on, so returning lands on that row rather
    /// than at the top of the page.
    ///
    /// The selected index is a display position, so it is resolved to a row through the grid's own
    /// mapping before anything is read off it: a per-column value filter makes display order and
    /// storage order diverge, and indexing the buffer directly would read a different row (#1837).
    private func capturePrimaryKeyAnchor(for tab: QueryTab) -> [String: String]? {
        let keyColumns = tab.tableContext.primaryKeyColumns
        guard !keyColumns.isEmpty,
              let gridCoordinator = dataTabDelegate?.tableViewCoordinator,
              let displayIndex = selectionState.indices.min() else { return nil }

        let tableRows = tabSessionRegistry.tableRows(for: tab.id)
        guard let row = gridCoordinator.displayRow(at: displayIndex, in: tableRows) else { return nil }

        var anchor: [String: String] = [:]
        for name in keyColumns {
            guard let column = tableRows.columns.firstIndex(of: name),
                  let value = row[column].asText else { return nil }
            anchor[name] = value
        }
        return anchor.isEmpty ? nil : anchor
    }

    // MARK: - Navigating

    func navigateBack() {
        step(back: true)
    }

    func navigateForward() {
        step(back: false)
    }

    /// Moves one entry and puts it back on the tab, or leaves the history exactly as it was.
    ///
    /// The stacks are mutated on a copy and only written back once the restore has actually landed.
    /// Moving them first would strand the reader if the retarget failed: the entry they asked for
    /// would be gone and Forward would point at the view they are still looking at.
    private func step(back: Bool) {
        guard let tabId = navigableTabId,
              var history = navigationHistories[tabId],
              let current = captureNavigationEntry() else { return }
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

    /// Puts a recorded location back on the selected tab.
    ///
    /// The sequence is `reuseActiveTab`'s, so a restore and an ordinary retarget reach the grid the
    /// same way. The difference is the state written between the retarget and the load: the
    /// recorded filters instead of the table's saved defaults, and the recorded sort and page
    /// through the pending fields the first load already knows how to consume.
    private func restore(_ entry: TabNavigationEntry, in tabId: UUID) -> Bool {
        do {
            try tabManager.replaceTabContent(
                tableName: entry.tableName,
                databaseType: connection.type,
                isView: entry.isView,
                databaseName: entry.databaseName,
                schemaName: entry.schemaName
            )
        } catch {
            navigationHistoryLogger.error(
                "restore replaceTabContent failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        discardRowsForRetarget(resultsViewMode: entry.resultsViewMode)
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex, tab.id == tabId else { return false }

        /// The page is always carried, not only when it is past the first. `replaceTabContent`
        /// resets pagination to the app's default page size, so a view recorded on page one of a
        /// 500-row page would otherwise come back in pages of a different size.
        tabManager.mutate(at: tabIndex) { tab in
            tab.filterState = entry.filterState
            tab.pendingRestoredSort = entry.sortColumns.isEmpty ? nil : entry.sortColumns
            tab.restoredPage = max(1, entry.page)
            tab.restoredPageSize = entry.pageSize
        }

        restoreLastHiddenColumnsForTable()
        filterCoordinator.rebuildTableQuery(at: tabIndex)
        cancelTableLoad(for: tabId)
        /// Keyed by tab because one `TableViewCoordinator` serves every tab in the window. An
        /// anchor with no tab attached would be spent by whichever tab's rows landed next.
        pendingRowAnchors[tabId] = entry.anchorRowKey
        lazyLoadCurrentTabIfNeeded()
        return true
    }
}
