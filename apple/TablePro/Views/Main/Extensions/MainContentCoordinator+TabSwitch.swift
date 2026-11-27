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
        if let oldTabId {
            commitGridEdit(ofTab: oldTabId)
            // A typed run left open would swallow the tab's next step when it comes back.
            existingChangeManager(forTab: oldTabId)?.endCoalescedUndoRun()
        }
        defer {
            isHandlingTabSwitch = false
            Self.lifecycleLogger.debug(
                "[switch] handleTabChange done to=\(newTabId?.uuidString ?? "nil", privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
            )
        }

        if let oldId = oldTabId,
           let oldIndex = tabManager.tabs.firstIndex(where: { $0.id == oldId })
        {
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

        // Deferred a tick: releasing a large formatted cache is not work the switch should wait on.
        Task { @MainActor [weak self] in
            self?.pruneGridDisplayCaches()
        }

        let restoreStart = Date()
        if let newId = newTabId,
           let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) {
            let newTab = tabManager.tabs[newIndex]

            toolbarState.isTableTab = newTab.tabType == .table
            toolbarState.isResultsCollapsed = newTab.display.isResultsCollapsed
            syncQueryToolbarState(for: newTab)

            // Each tab keeps its own edits and undo history, so arriving only points the window at them.
            describeCurrentResult(ofTab: newId)
            selectedTabEdits.follow(changeManager(forTab: newId))
            Self.lifecycleLogger.debug(
                "[switch] handleTabChange restoreIncoming=\(Int(Date().timeIntervalSince(restoreStart) * 1_000))ms"
            )

            // No `reloadVersion` bump: bumping it on a switch re-formatted the incoming grid's whole result (#2424).
            let isStale = tabSessionRegistry.isStale(newId)
            lazyLoadCurrentTabIfNeeded()
            TabSwitchTracer.shared.selectionApplied(
                tabId: newId,
                rows: TabSwitchRows(loads: isLoadingRows(newId), needsReload: isStale),
                window: contentWindow,
                isShowing: { [weak manager = tabManager] in manager?.isShowing(newId) ?? false }
            )
        } else {
            selectedTabEdits.follow(idleChangeManager)
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
