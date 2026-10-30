//
//  MainContentCoordinator+TabSwitch.swift
//  TablePro
//
//  Tab switching logic extracted from MainContentCoordinator
//  to keep the main class body within SwiftLint limits.
//

import Foundation
import os
import TableProEditorKit

extension MainContentCoordinator {
    func handleTabChange(
        from oldTabId: UUID?,
        to newTabId: UUID?,
        tabs: [QueryTab]
    ) {
        if let newTabId {
            OperationUnseenMarker.clear(tabId: newTabId, in: tabManager)
            OperationCompletionReporter.shared.clearDelivered(for: operationOwner(tabId: newTabId))
        }
        let start = Date()
        Self.lifecycleLogger.debug(
            "[switch] handleTabChange start from=\(oldTabId?.uuidString ?? "nil", privacy: .public) to=\(newTabId?.uuidString ?? "nil", privacy: .public) connId=\(self.connectionId, privacy: .public) tabsCount=\(self.tabManager.tabs.count)"
        )
        isHandlingTabSwitch = true
        defer {
            isHandlingTabSwitch = false
            Self.lifecycleLogger.debug(
                "[switch] handleTabChange done to=\(newTabId?.uuidString ?? "nil", privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
            )
        }

        let saveStart = Date()
        if let oldId = oldTabId,
           let oldIndex = tabManager.tabs.firstIndex(where: { $0.id == oldId })
        {
            /// The second half of the condition is the fix. Gated on `hasChanges` alone, an undo was
            /// never recorded: the tab kept the snapshot a previous switch had saved, so switching
            /// back restored the edit the reader had just taken back and the tab went on reporting
            /// unsaved work. Writing the empty snapshot is what clears it.
            ///
            /// Still conditional, because `mutate` takes the element `inout` and so runs the array's
            /// setter whether or not the block writes: an unconditional write would fire `tabs`'
            /// `didSet` over every open tab on every switch, for nothing.
            ///
            /// Safe to take the snapshot from the change manager here because nothing has repointed
            /// it yet: every other `configureForTable` and `restoreState` caller is either the
            /// incoming block below or guarded to the selected tab, and this runs synchronously
            /// from the selection change with no suspension in between.
            if changeManager.hasChanges || tabManager.tabs[oldIndex].pendingChanges.hasChanges {
                let savedState = changeManager.saveState()
                tabManager.mutate(at: oldIndex) { $0.pendingChanges = savedState }
            }
            // One editor serves every query tab, so `cursorPositions` describes the outgoing tab
            // only until the switch completes. Persistence writes the live caret for the selected
            // tab alone, so a caret not captured here is gone once the editor has consumed the
            // tab's restored value.
            //
            // Only a tab whose own restored caret is already consumed can be written, because the
            // query editor subtree has no `.id(tab.id)`: selecting a restored tab reuses the same
            // editor without re-installing it, so `cursorPositions` can still describe the tab
            // before it. Overwriting there would destroy the very caret this is meant to keep.
            let outgoing = tabManager.tabs[oldIndex]
            if outgoing.tabType == .query,
               outgoing.restoredCursorOffset == nil,
               outgoing.restoredCursorLength == nil,
               let range = cursorPositions.first?.range {
                tabManager.mutate(at: oldIndex) {
                    $0.restoredCursorOffset = range.location
                    $0.restoredCursorLength = range.length
                }
            }
            /// Before the restore below repoints `selectionState` at the incoming tab. The outgoing
            /// grid is still mounted and still bound to that shared channel, so the repoint clears
            /// its table view and its own teardown then has nothing left to report. (#2667)
            if let live = mountedGridSelection() {
                storeGridSelection(rows: live.rows, cells: live.cells, forTab: oldId)
            }
            filterCoordinator.saveLastFilters(of: tabManager.tabs[oldIndex])
        }
        let saveMs = Int(Date().timeIntervalSince(saveStart) * 1_000)

        let restoreStart = Date()
        if let newId = newTabId,
           let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) {
            let newTab = tabManager.tabs[newIndex]
            let newRows = tabSessionRegistry.tableRows(for: newId)

            selectionState.indices = newTab.selectedDisplayRows
            toolbarState.isTableTab = newTab.tabType == .table
            toolbarState.isResultsCollapsed = newTab.display.isResultsCollapsed
            syncQueryToolbarState(for: newTab)

            /// Consumed once restored. The change manager is the selected tab's edits from here, and
            /// a copy left on the tab went stale with the first undo: it went on reporting edits the
            /// reader had taken back, and a reload put off for them never ran.
            let pendingState = newTab.pendingChanges
            if pendingState.hasChanges {
                changeManager.restoreState(
                    from: pendingState,
                    tableName: newTab.tableContext.tableName ?? "",
                    schemaName: newTab.tableContext.schemaName,
                    databaseType: connection.type,
                    generatedColumns: newRows.generatedColumns,
                    rowMatchPolicy: newRows.rowMatchPolicy,
                    columnTypeNames: newRows.columnTypeNames
                )
                tabManager.mutate(at: newIndex) { $0.pendingChanges = TabChangeSnapshot() }
            } else {
                changeManager.configureForTable(
                    tableName: newTab.tableContext.tableName ?? "",
                    schemaName: newTab.tableContext.schemaName,
                    columns: newRows.columns,
                    primaryKeyColumns: newTab.tableContext.primaryKeyColumns,
                    databaseType: connection.type,
                    generatedColumns: newRows.generatedColumns,
                    rowMatchPolicy: newRows.rowMatchPolicy,
                    columnTypeNames: newRows.columnTypeNames,
                    triggerReload: false
                )
            }

            let restoreMs = Int(Date().timeIntervalSince(restoreStart) * 1_000)
            Self.lifecycleLogger.debug(
                "[switch] handleTabChange phases: saveOutgoing=\(saveMs)ms restoreIncoming=\(restoreMs)ms"
            )

            // No `reloadVersion` bump here. It is the change manager's throw-away-and-fetch-again
            // signal and it is shared by every tab in the window, so bumping it on a switch told
            // the incoming grid its rows had changed and made it re-format the whole result. The
            // reload a switch does need is already forced by the freshly mounted grid's zero row
            // count, and a real content change still arrives through `configureForTable`. (#2424)
            let isStale = tabSessionRegistry.isStale(newId)
            lazyLoadCurrentTabIfNeeded()
            TabSwitchTracer.shared.selectionApplied(
                tabId: newId,
                rows: TabSwitchRows(loads: isLoadingRows(newId), needsReload: isStale),
                window: contentWindow,
                isShowing: { [weak manager = tabManager] in manager?.isShowing(newId) ?? false }
            )
        } else {
            /// An entry with no tab of its own. The outgoing tab's edits were saved onto it above,
            /// and the live copy goes: the change manager is the selected tab's, and with none
            /// selected a Save would write those rows against the database now on screen.
            selectionState.indices = []
            changeManager.configureForTable(
                tableName: "",
                columns: [],
                primaryKeyColumns: [],
                databaseType: connection.type,
                generatedColumns: [],
                triggerReload: false
            )
            toolbarState.isTableTab = false
            toolbarState.isResultsCollapsed = false
            toolbarState.isQueryTab = false
            toolbarState.hasQueryText = false
        }
    }

    // For a tab that comes on screen without a selection change, before its pane restarts any load.
    func arrivingRows(for tabId: UUID) -> TabSwitchRows {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return .resident }
        return TabSwitchRows(
            loads: isLoadingRows(tabId) || canAutoLoadTableTab(tab),
            needsReload: tabSessionRegistry.isStale(tabId)
        )
    }

    // Only a traced load reports its end; a multi-statement run does not, and would hold the switch open.
    private func isLoadingRows(_ tabId: UUID) -> Bool {
        TableLoadTracer.shared.activeToken(for: tabId) != nil
    }

    /// What the toolbar's Run, Explain, Format and Favorite items validate against.
    ///
    /// Execution state is deliberately not among these: `TabExecutionRegistry` is the single answer
    /// to "is something running", and its own documentation records that a hand-kept mirror of that
    /// is what let the titlebar report a query which had already ended (#2342). The toolbar reads
    /// it live through `isSelectedTabExecuting`.
    func syncQueryToolbarState(for tab: QueryTab) {
        toolbarState.isQueryTab = tab.tabType == .query
        toolbarState.hasQueryText = tab.tabType == .query && tab.hasQueryText
    }

    func syncQueryToolbarStateForSelectedTab() {
        guard let tab = tabManager.selectedTab else {
            toolbarState.isQueryTab = false
            toolbarState.hasQueryText = false
            return
        }
        syncQueryToolbarState(for: tab)
    }

    /// Whether the tab the toolbar is pointed at has a query in flight, asked of the registry each
    /// time rather than stored.
    var isSelectedTabExecuting: Bool {
        guard let tabId = tabManager.selectedTabId else { return false }
        return tabExecution.isExecuting(tabId)
    }
}
