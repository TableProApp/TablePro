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
        // The change manager holds the outgoing tab's edits until the restore below, so an open cell editor commits there (H2).
        tabSwitchOutgoingTabId = oldTabId
        if let oldTabId {
            commitGridEdit(ofTab: oldTabId)
        }
        defer {
            tabSwitchOutgoingTabId = nil
            isHandlingTabSwitch = false
            Self.lifecycleLogger.debug(
                "[switch] handleTabChange done to=\(newTabId?.uuidString ?? "nil", privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
            )
        }

        let saveStart = Date()
        if let oldId = oldTabId,
           let oldIndex = tabManager.tabs.firstIndex(where: { $0.id == oldId })
        {
            // Also checks the tab's snapshot: on `hasChanges` alone an undo kept a stale snapshot that restored the undone edit on return.
            if changeManager.hasChanges || tabManager.tabs[oldIndex].pendingChanges.hasChanges {
                let savedState = changeManager.saveState()
                tabManager.mutate(at: oldIndex) { $0.pendingChanges = savedState }
            }
            // One editor serves every query tab with no `.id(tab.id)`, so write only once this tab's restored caret has been consumed.
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
            filterCoordinator.saveLastFilters(of: tabManager.tabs[oldIndex])
        }
        let saveMs = Int(Date().timeIntervalSince(saveStart) * 1_000)

        // Deferred a tick: releasing a large formatted cache is not work the switch should wait on.
        Task { @MainActor [weak self] in
            self?.pruneGridDisplayCaches()
        }

        let restoreStart = Date()
        if let newId = newTabId,
           let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) {
            let newTab = tabManager.tabs[newIndex]
            let newRows = tabSessionRegistry.tableRows(for: newId)

            toolbarState.isTableTab = newTab.tabType == .table
            toolbarState.isResultsCollapsed = newTab.display.isResultsCollapsed
            syncQueryToolbarState(for: newTab)

            // Consumed once restored: a copy left on the tab went stale with the first undo and kept reporting undone edits.
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
                tabSwitchOutgoingTabId = nil
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
                tabSwitchOutgoingTabId = nil
            }

            let restoreMs = Int(Date().timeIntervalSince(restoreStart) * 1_000)
            Self.lifecycleLogger.debug(
                "[switch] handleTabChange phases: saveOutgoing=\(saveMs)ms restoreIncoming=\(restoreMs)ms"
            )

            // No `reloadVersion` bump: it is window-wide, and bumping it on a switch re-formatted the incoming grid's whole result (#2424).
            let isStale = tabSessionRegistry.isStale(newId)
            lazyLoadCurrentTabIfNeeded()
            TabSwitchTracer.shared.selectionApplied(
                tabId: newId,
                rows: TabSwitchRows(loads: isLoadingRows(newId), needsReload: isStale),
                window: contentWindow,
                isShowing: { [weak manager = tabManager] in manager?.isShowing(newId) ?? false }
            )
        } else {
            // No tab selected: drop the live copy, or a Save would write the outgoing tab's rows against the database now on screen.
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

    private func commitGridEdit(ofTab tabId: UUID) {
        existingGridModel(forTab: tabId)?.commitEditing()
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return }
        activeGridModelProvider(for: tab)?.activeGridModel?.commitEditing()
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

    // No execution state here: a hand-kept mirror let the titlebar show an ended query (#2342), so the toolbar reads the registry.
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

    var isSelectedTabExecuting: Bool {
        guard let tabId = tabManager.selectedTabId else { return false }
        return tabExecution.isExecuting(tabId)
    }
}
