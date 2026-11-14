//
//  MainContentCoordinator+ExecuteAll.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    // A run replaces the result the staged edits belong to. A tab with no result has none of its own:
    // for a turn after a switch the change manager still holds the outgoing tab's.
    func confirmRunDiscard(onTab tabId: UUID, then run: @escaping () -> Void) {
        guard let tab = tabManager.selectedTabAndIndex?.tab, tab.id == tabId, tab.display.activeResultSet != nil else {
            commitActiveGridEdit()
            run()
            return
        }
        confirmDiscardRestoringRowsIfNeeded(forTab: tabId, action: .run) { [weak self] confirmed in
            guard let self, confirmed, tabManager.selectedTabId == tabId, !tabExecution.isExecuting(tabId) else { return }
            run()
        }
    }

    func flushEditorText(forTab tabId: UUID) {
        EditorEventRouter.shared.flushPendingText(forTab: tabId, connectionId: connectionId)
    }
}
