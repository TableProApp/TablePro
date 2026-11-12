//
//  MainContentCoordinator+ExecuteAll.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func runAllStatements(extraCapabilities: CallerCapabilities = []) {
        guard let tab = tabManager.selectedTabAndIndex?.tab, tab.tabType == .query,
              !tabExecution.isExecuting(tab.id) else { return }
        confirmRunDiscard(onTab: tab.id) { [weak self] in
            guard let self else { return }
            flushEditorText(forTab: tab.id)
            endEditorCompletion()
            queryExecutionCoordinator.runAllStatements(extraCapabilities: extraCapabilities)
        }
    }

    // A run authorized for a tab stays on it; nil is the selected tab.
    func executionTab(_ tabId: UUID?) -> (tab: QueryTab, index: Int)? {
        guard let tabId else { return tabManager.selectedTabAndIndex }
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        return (tabManager.tabs[index], index)
    }

    // A run replaces the result the staged edits belong to. A tab with no result has none of its own:
    // for a turn after a switch the change manager still holds the outgoing tab's.
    func confirmRunDiscard(onTab tabId: UUID, then run: @escaping () -> Void) {
        guard let tab = tabManager.selectedTabAndIndex?.tab, tab.id == tabId, tab.display.activeResultSet != nil else {
            commitActiveGridEdit()
            run()
            return
        }
        confirmDiscardRestoringRowsIfNeeded(action: .run) { [weak self] confirmed in
            guard let self, confirmed, tabManager.selectedTabId == tabId, !tabExecution.isExecuting(tabId) else { return }
            run()
        }
    }

    func flushEditorText(forTab tabId: UUID) {
        EditorEventRouter.shared.flushPendingText(forTab: tabId, connectionId: connectionId)
    }

    internal func dispatchBatches(
        _ batches: [ExecutableBatch],
        tabIndex index: Int,
        bypassRowLimit: Bool = false,
        extraCapabilities: CallerCapabilities = []
    ) {
        queryExecutionCoordinator.dispatchBatches(
            batches,
            tabIndex: index,
            bypassRowLimit: bypassRowLimit,
            extraCapabilities: extraCapabilities
        )
    }

    internal func dispatchParameterizedBatches(
        _ batches: [ExecutableBatch],
        parameters: [QueryParameter],
        tabIndex index: Int,
        bypassRowLimit: Bool = false,
        extraCapabilities: CallerCapabilities = []
    ) {
        queryExecutionCoordinator.dispatchParameterizedBatches(
            batches,
            parameters: parameters,
            tabIndex: index,
            bypassRowLimit: bypassRowLimit,
            extraCapabilities: extraCapabilities
        )
    }
}
