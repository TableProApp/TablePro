//
//  ConnectionDisconnectAction.swift
//  TablePro
//

import AppKit
import Foundation

// Every surface's disconnect lands here, so the confirmation exists once.
@MainActor
internal enum ConnectionDisconnectAction {
    internal static func disconnect(
        connectionId: UUID,
        connectionName: String,
        presentingWindow: NSWindow?,
        registry: RunningWorkRegistry = .shared
    ) async {
        let holding = await DatabaseManager.shared.databasesHoldingTransaction(for: connectionId)
        let hasUnsavedWork = MainContentCoordinator.hasUnsavedWork(forConnection: connectionId)
        let work = registry.items(in: .connection(connectionId))
        if let prompt = RunningWorkPrompt.make(
            action: .disconnect,
            work: work,
            otherLosses: otherLosses(holdingTransaction: holding, hasUnsavedWork: hasUnsavedWork)
        ) {
            guard await RunningWorkApproval.confirm(prompt, window: presentingWindow) else { return }
            registry.cancel(work)
        } else if let message = confirmationMessage(holdingTransaction: holding, hasUnsavedWork: hasUnsavedWork) {
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

    // Nil means disconnect without asking: ending a session the user asked to end loses nothing.
    internal static func confirmationMessage(holdingTransaction holding: [String], hasUnsavedWork: Bool) -> String? {
        if let message = transactionMessage(for: holding) {
            return message
        }
        return hasUnsavedWork ? String(localized: "Unsaved changes will be lost.") : nil
    }

    internal static func otherLosses(holdingTransaction holding: [String], hasUnsavedWork: Bool) -> [String] {
        var losses = RunningWorkPrompt.transactionLines(for: holding)
        if hasUnsavedWork {
            losses.append(String(localized: "Unsaved changes"))
        }
        return losses
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
