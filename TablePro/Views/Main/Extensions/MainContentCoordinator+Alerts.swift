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
    // MARK: - Dangerous Query Confirmation

    /// Check if query needs confirmation and show alert if needed
    /// - Parameter sql: SQL query to check
    /// - Returns: true if safe to execute, false if user cancelled
    func confirmDangerousQueryIfNeeded(_ sql: String, window: NSWindow? = nil) async -> Bool {
        guard isDangerousQuery(sql) else { return true }

        let message = dangerousQueryMessage(for: sql)
        return await AlertHelper.confirmCritical(
            title: String(localized: "Potentially Dangerous Query"),
            message: message,
            confirmButton: String(localized: "Execute"),
            cancelButton: String(localized: "Cancel"),
            window: window
        )
    }

    /// Generate appropriate message for dangerous query type
    private func dangerousQueryMessage(for sql: String) -> String {
        let uppercased = sql.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if uppercased.hasPrefix("DROP ") {
            return String(localized: "This DROP query will permanently remove database objects. This action cannot be undone.")
        } else if uppercased.hasPrefix("TRUNCATE ") {
            return String(localized: "This TRUNCATE query will permanently delete all rows in the table. This action cannot be undone.")
        } else if uppercased.hasPrefix("DELETE ") {
            return String(localized: "This DELETE query has no WHERE clause and will delete ALL rows in the table. This action cannot be undone.")
        }

        return String(localized: "This query may permanently modify or delete data.")
    }

    /// Check multiple queries for dangerous operations and show a single batch confirmation
    /// - Parameter statements: Array of dangerous SQL statements
    /// - Returns: true if user confirmed, false if cancelled
    func confirmDangerousQueries(_ statements: [String], window: NSWindow? = nil) async -> Bool {
        guard !statements.isEmpty else { return true }

        let querySummaries = statements.map { stmt -> String in
            let trimmed = stmt.trimmingCharacters(in: .whitespacesAndNewlines)
            // Show first 80 chars of each query
            if (trimmed as NSString).length > 80 {
                return String(trimmed.prefix(80)) + "..."
            }
            return trimmed
        }

        let queryList = querySummaries.joined(separator: "\n")
        let message = String(
            localized: "The following \(statements.count) queries may permanently modify or delete data. This action cannot be undone.\n\n\(queryList)"
        )

        return await AlertHelper.confirmCritical(
            title: String(localized: "Potentially Dangerous Queries"),
            message: message,
            confirmButton: String(localized: "Execute All"),
            cancelButton: String(localized: "Cancel"),
            window: window
        )
    }

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
        }
    }

    // MARK: - Error Alerts

    /// Show query execution error as a sheet
    /// - Parameters:
    ///   - error: The error that occurred
    ///   - window: Parent window (optional)
    func showQueryError(_ error: Error, window: NSWindow?) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Query Execution Failed"),
            message: error.localizedDescription,
            window: window
        )
    }

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
