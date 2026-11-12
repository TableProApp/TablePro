//
//  MainContentCoordinator+ContainerChange.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    // Everything the tab was doing belongs to the object it named: its run, its edit in progress and the cached metadata.
    internal func retargetTab(_ tabId: UUID) {
        existingGridModel(forTab: tabId)?.discardEditing()
        flushColumnLayoutPersistence()
        supersedeExecution(for: tabId)
        releaseRetargetedTabState(for: tabId)
    }

    // A rebind is a retarget: rows read from the old container must never land, or stay editable, under the new one.
    internal func changeQueryContainer(of tabId: UUID, to name: String, target: ContainerSwitchTarget?) {
        guard canChangeContainer(of: tabId, to: name) else { return }
        // Asked before the tab moves, so Cancel leaves the staged edits with the database their rows came from.
        confirmDiscardRestoringRowsIfNeeded(action: .containerChange) { [weak self] confirmed in
            guard confirmed, let self, canChangeContainer(of: tabId, to: name) else { return }
            retargetTab(tabId)
            guard tabManager.mutate(tabId: tabId, { tab in
                QueryContainerRebinding.rebind(&tab.tableContext, to: name, target: target)
                // Rows still on screen were read from the old container; Load More would page them from the new one.
                tab.pagination.resetLoadMore()
            }) else { return }
            tabManager.markTabRenamed(tabId)
            SchemaProviderRegistry.shared.reclaimUnheldProviders(for: connectionId)
            guard ContainerChangeRerunPolicy.reruns(showing: tabManager.selectedTab?.display.activeResultSet) else { return }
            // The statement at the caret may not be the one that produced the rows, so a write asks first.
            runQuery(viewport: .firstRow, extraCapabilities: .confirmsWrites)
        }
    }

    // The picker is off while the tab runs: a running tab moved elsewhere would land its rows under the new database.
    private func canChangeContainer(of tabId: UUID, to name: String) -> Bool {
        guard tabManager.selectedTabId == tabId, !tabExecution.isExecuting(tabId),
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return false }
        return tabManager.containerName(of: tab) != name
    }
}
