//
//  ConnectionDisconnectAction.swift
//  TablePro
//

import AppKit
import Foundation

/// The one path a user-requested disconnect takes, whatever surface asked for it. The menu bar, the
/// workspace rail and the connection list all land here so the confirmation exists once and reads
/// the same everywhere.
@MainActor
internal enum ConnectionDisconnectAction {
    internal static func disconnect(
        connectionId: UUID,
        connectionName: String,
        presentingWindow: NSWindow?
    ) async {
        if let message = await confirmationMessage(for: connectionId) {
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(format: String(localized: "Disconnect from “%@”?"), connectionName),
                message: message,
                confirmButton: String(localized: "Disconnect"),
                window: presentingWindow
            )
            guard confirmed else { return }
        }
        await DatabaseManager.shared.disconnectSession(connectionId, origin: .userRequested)
    }

    /// Nil means disconnect without asking. Losing work the user cannot get back is worth an alert;
    /// ending a session they asked to end is not, which is why a clean connection never sees one.
    private static func confirmationMessage(for connectionId: UUID) async -> String? {
        let holding = await DatabaseManager.shared.databasesHoldingTransaction(for: connectionId)
        if let message = transactionMessage(for: holding) {
            return message
        }
        if MainContentCoordinator.hasUnsavedWork(forConnection: connectionId) {
            return String(localized: "Unsaved changes will be lost.")
        }
        if MainContentCoordinator.hasRunningQuery(forConnection: connectionId) {
            return String(localized: "A query is still running. Disconnecting cancels it.")
        }
        return nil
    }

    internal static func transactionMessage(for databases: [String]) -> String? {
        guard let first = databases.first else { return nil }
        guard databases.count > 1 else {
            return String(
                format: String(localized: "The database “%@” has an open transaction. Disconnecting rolls it back and discards its uncommitted changes."),
                first
            )
        }
        return String(
            format: String(localized: "These databases have open transactions: %@. Disconnecting rolls them back and discards their uncommitted changes."),
            ListFormatter.localizedString(byJoining: databases.map { "“\($0)”" })
        )
    }
}
