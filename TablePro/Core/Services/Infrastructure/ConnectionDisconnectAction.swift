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
        if let message = confirmationMessage(for: connectionId) {
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
    private static func confirmationMessage(for connectionId: UUID) -> String? {
        if MainContentCoordinator.hasUnsavedWork(forConnection: connectionId) {
            return String(localized: "Unsaved changes will be lost.")
        }
        if MainContentCoordinator.hasRunningQuery(forConnection: connectionId) {
            return String(localized: "A query is still running. Disconnecting cancels it.")
        }
        return nil
    }
}
