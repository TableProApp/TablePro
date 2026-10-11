//
//  MainContentCoordinator+ReopenClosedTab.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// Takes a tab rebuilt from the recently closed history into this connection's list, on the
    /// terms a restored session brings its tabs back: a table tab gets its hidden columns and
    /// filters before it loads, rather than a first page drawn without them.
    internal func adoptRestoredTab(_ tab: QueryTab) {
        tabManager.adoptTab(tab, claimFocus: tab.tabType == .query)
        guard tab.tabType == .table, tab.tableContext.tableName != nil else { return }
        restoreLastHiddenColumnsForTable()
        restoreFiltersForSelectedTab()
        lazyLoadCurrentTabIfNeeded(trigger: .restore)
    }

    internal func land(_ move: PendingTabMove, afterWaiting: Bool) {
        guard hasSettledTabRestore else {
            movesAwaitingRestore.append(move)
            return
        }
        /// A connection first opened onto one table or query never read its saved tabs, so it cannot
        /// write the moved one yet. It reads them now; the merge leaves out any tab another window holds.
        guard persistence.hasObservedTabs else {
            hasSettledTabRestore = false
            movesAwaitingRestore.append(move)
            Task { [weak self] in
                await self?.restoreSavedTabs()
                self?.settleTabRestore()
            }
            return
        }
        move.land(in: self, afterWaiting: afterWaiting)
    }

    internal func settleTabRestore() {
        guard !hasSettledTabRestore else { return }
        hasSettledTabRestore = true
        let waiting = movesAwaitingRestore
        movesAwaitingRestore.removeAll()
        for move in waiting {
            move.land(in: self, afterWaiting: true)
        }
    }

    internal func dropMovesAwaitingRestore(reason: String) {
        let waiting = movesAwaitingRestore
        movesAwaitingRestore.removeAll()
        for move in waiting {
            move.drop(reason: reason)
        }
    }

    internal func adoptMovedTab(_ tab: QueryTab) {
        let moved = tab.movedToConnection(
            databaseName: browseDatabaseName,
            schemaName: browseScope?.schema,
            existingTabs: Self.allTabs(for: connectionId) + tabManager.tabs,
            defaultPageSize: services.appSettings.dataGrid.defaultPageSize
        )
        tabManager.adoptTab(moved, claimFocus: true)
    }
}
