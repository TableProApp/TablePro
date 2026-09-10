//
//  MainContentCoordinator+ChangeGuard.swift
//  TablePro
//
//  Guard against data-destructive operations when unsaved changes exist.
//  Provides a reusable confirmation gate for sort, pagination, and filter operations.
//

import AppKit
import Foundation

extension MainContentCoordinator {
    /// Check for unsaved changes and prompt user to confirm discarding them.
    /// Returns true if the caller is safe to proceed (no changes, or user chose to discard).
    func confirmDiscardChangesIfNeeded(
        action: DiscardAction,
        completion: @escaping (Bool) -> Void
    ) {
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

    /// The same gate, for an operation that does NOT re-query.
    ///
    /// An edit is written into the tab's loaded rows as well as being recorded, so every caller of
    /// the plain gate above gets away with clearing only the records: sort, pagination, the WHERE
    /// filter and refresh all re-run the query and replace the buffer. A per-column value filter
    /// narrows the rows already loaded, so the edited values would stay on screen with nothing
    /// tracking them, and the next edit would capture an unsaved value as its baseline. (#2667)
    func confirmDiscardRestoringRowsIfNeeded(
        action: DiscardAction,
        completion: @escaping (Bool) -> Void
    ) {
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
