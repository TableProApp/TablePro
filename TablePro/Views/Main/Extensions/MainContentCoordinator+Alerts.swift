//
//  MainContentCoordinator+Alerts.swift
//  TablePro
//
//  Alert handling methods for MainContentCoordinator
//  Centralizes all NSAlert logic for main content operations
//

import AppKit
import Foundation

extension MainContentCoordinator {
    // MARK: - Discard Changes Confirmation

    /// Confirm discarding unsaved changes
    /// - Parameter action: The action that requires discarding changes
    /// - Returns: true if user confirmed, false if cancelled
    func confirmDiscardChanges(action: DiscardAction, window: NSWindow? = nil) async -> Bool {
        guard !isShowingConfirmAlert else { return false }
        isShowingConfirmAlert = true
        defer { isShowingConfirmAlert = false }

        let message = discardMessage(for: action)
        return await AlertHelper.confirmDestructive(
            title: String(localized: "Discard Unsaved Changes?"),
            message: message,
            confirmButton: String(localized: "Discard"),
            cancelButton: String(localized: "Cancel"),
            window: window
        )
    }

    /// Generate appropriate message for discard action type
    private func discardMessage(for action: DiscardAction) -> String {
        switch action {
        case .refresh:
            return String(localized: "Refreshing will discard all unsaved changes.")
        case .sort:
            return String(localized: "Sorting will reload data and discard all unsaved changes.")
        case .pagination:
            return String(localized: "Navigating to another page will discard all unsaved changes.")
        case .filter:
            return String(localized: "Applying or clearing filters will reload data and discard all unsaved changes.")
        case .resultSwitch:
            return String(localized: "Showing another result will discard all unsaved changes.")
        /// Worded for both directions, because Forward reaches the same guard. Naming Back here
        /// misstated the operation the user was approving whenever they stepped forward.
        case .navigation:
            return String(localized: "Moving through this tab's history replaces what it is showing and will discard all unsaved changes.")
        /// No mention of reloading, unlike sort and the WHERE filter: a value filter narrows the
        /// rows already loaded and never re-queries. What it does change is which row each display
        /// position names, which is what the edits are recorded against.
        case .displayOrder:
            return String(localized: "Changing which rows are shown will discard all unsaved changes.")
        }
    }

    // MARK: - Error Alerts

    /// Show save changes error as a sheet
    /// - Parameters:
    ///   - error: The error that occurred
    ///   - window: Parent window (optional)
    func showSaveError(_ error: Error, window: NSWindow?) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Failed to Save Changes"),
            message: error.localizedDescription,
            window: window
        )
    }
}
