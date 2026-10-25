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
        commitActiveGridEdit()
        guard changeManager.hasChanges else {
            completion(true)
            return
        }

        guard !isShowingConfirmAlert else {
            completion(false)
            return
        }

        Task {
            let confirmed = await confirmDiscardChanges(action: action, window: contentWindow)
            if confirmed {
                changeManager.clearChangesAndUndoHistory()
            }
            completion(confirmed)
        }
    }

    // Not the plain gate: a value filter keeps the loaded rows, so edited values would stay on screen untracked (#2667).
    func confirmDiscardRestoringRowsIfNeeded(
        action: DiscardAction,
        completion: @escaping (Bool) -> Void
    ) {
        commitActiveGridEdit()
        guard changeManager.hasChanges else {
            completion(true)
            return
        }

        guard !isShowingConfirmAlert else {
            completion(false)
            return
        }

        Task {
            let confirmed = await confirmDiscardChanges(action: action, window: contentWindow)
            if confirmed {
                rowEditingCoordinator.restoreRowBufferToOriginals()
                changeManager.clearChangesAndUndoHistory()
                if let (_, index) = tabManager.selectedTabAndIndex {
                    tabManager.mutate(at: index) { $0.pendingChanges = TabChangeSnapshot() }
                }
            }
            completion(confirmed)
        }
    }
}
