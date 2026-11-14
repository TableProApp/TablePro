//
//  MainContentCoordinator+ChangeGuard.swift
//  TablePro
//

import AppKit
import Foundation

extension MainContentCoordinator {
    func confirmDiscardChangesIfNeeded(
        action: DiscardAction,
        completion: @escaping (Bool) -> Void
    ) {
        confirmDiscard(forTab: tabManager.selectedTabId, action: action, completion: completion)
    }

    func confirmDiscardChangesIfNeeded(
        forTab tabId: UUID,
        action: DiscardAction,
        completion: @escaping (Bool) -> Void
    ) {
        confirmDiscard(forTab: tabId, action: action, completion: completion)
    }

    // The tab is fixed before the alert, since the selection can move while it is up. Its rows go back to their
    // originals with the edits: a reload that is refused, fails or never runs would leave edited values on screen untracked (#2667).
    private func confirmDiscard(
        forTab tabId: UUID?,
        action: DiscardAction,
        completion: @escaping (Bool) -> Void
    ) {
        commitActiveGridEdit()
        let manager = tabId.map { changeManager(forTab: $0) } ?? changeManager
        guard manager.hasChanges else {
            completion(true)
            return
        }

        guard !isShowingConfirmAlert else {
            completion(false)
            return
        }

        Task {
            let confirmed = await confirmDiscardChanges(action: action, window: contentWindow)
            guard confirmed else {
                completion(false)
                return
            }
            if let tabId {
                guard tabManager.tabs.contains(where: { $0.id == tabId }) else {
                    completion(false)
                    return
                }
                rowEditingCoordinator.restoreRowBufferToOriginals(forTab: tabId)
            }
            manager.clearChangesAndUndoHistory()
            completion(true)
        }
    }
}
