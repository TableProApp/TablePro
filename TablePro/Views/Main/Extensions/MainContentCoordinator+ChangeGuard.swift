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

        Task { @MainActor in
            let window = NSApp.keyWindow
            let confirmed = await confirmDiscardChanges(action: action, window: window)
            if confirmed {
                changeManager.clearChanges()
            }
            completion(confirmed)
        }
    }
}
