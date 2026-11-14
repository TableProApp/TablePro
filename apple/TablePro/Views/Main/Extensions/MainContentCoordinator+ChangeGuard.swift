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
        confirmDiscard(forTab: tabManager.selectedTabId, action: action, restoringRows: false, completion: completion)
    }

    func confirmDiscardChangesIfNeeded(
        forTab tabId: UUID,
        action: DiscardAction,
        completion: @escaping (Bool) -> Void
    ) {
        confirmDiscard(forTab: tabId, action: action, restoringRows: false, completion: completion)
    }

    // Not the plain gate: a value filter keeps the loaded rows, so edited values would stay on screen untracked (#2667).
    func confirmDiscardRestoringRowsIfNeeded(
        action: DiscardAction,
        completion: @escaping (Bool) -> Void
    ) {
        confirmDiscard(forTab: tabManager.selectedTabId, action: action, restoringRows: true, completion: completion)
    }

    func confirmDiscardRestoringRowsIfNeeded(
        forTab tabId: UUID,
        action: DiscardAction,
        completion: @escaping (Bool) -> Void
    ) {
        confirmDiscard(forTab: tabId, action: action, restoringRows: true, completion: completion)
    }

    // The tab is fixed before the alert: the selection can move while it is up, and its edits are the ones asked about.
    private func confirmDiscard(
        forTab tabId: UUID?,
        action: DiscardAction,
        restoringRows: Bool,
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
                if restoringRows {
                    rowEditingCoordinator.restoreRowBufferToOriginals(forTab: tabId)
                }
            }
            manager.clearChangesAndUndoHistory()
            completion(true)
        }
    }
}
