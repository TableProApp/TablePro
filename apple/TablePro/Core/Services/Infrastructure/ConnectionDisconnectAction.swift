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
        let hasUnsavedWork = MainContentCoordinator.hasUnsavedWork(forConnection: connectionId)
        let work = registry.items(in: .connection(connectionId))
        var namedUnsavedWork = false
        if let prompt = RunningWorkPrompt.make(
            action: .disconnect,
            work: work,
            otherLosses: otherLosses(hasUnsavedWork: hasUnsavedWork)
        ) {
            guard await RunningWorkApproval.confirm(prompt, window: presentingWindow) else { return }
            namedUnsavedWork = hasUnsavedWork
        }
        switch await TransactionEndingFlow.resolve(
            connectionId: connectionId,
            action: .disconnect(name: connectionName),
            hasUnsavedWork: hasUnsavedWork && !namedUnsavedWork,
            window: { presentingWindow }
        ) {
        case .cancelled:
            return
        case .ended:
            break
        case .nothingOpen:
            let unsaved = MainContentCoordinator.hasUnsavedWork(forConnection: connectionId)
            if !namedUnsavedWork, let message = confirmationMessage(hasUnsavedWork: unsaved) {
                let confirmed = await AlertHelper.confirmDestructive(
                    title: String(format: String(localized: "Disconnect from “%@”?"), connectionName),
                    message: message,
                    confirmButton: String(localized: "Disconnect"),
                    window: presentingWindow
                )
                guard confirmed else { return }
            }
        }
        // Stopped only once every answer is in and any commit landed.
        registry.cancel(work)
        await DatabaseManager.shared.disconnectSession(connectionId, origin: .userRequested)
    }

    // Nil means disconnect without asking: ending a session the user asked to end loses nothing.
    internal static func confirmationMessage(hasUnsavedWork: Bool) -> String? {
        hasUnsavedWork ? String(localized: "Unsaved changes will be lost.") : nil
    }

    internal static func otherLosses(hasUnsavedWork: Bool) -> [String] {
        hasUnsavedWork ? [String(localized: "Unsaved changes")] : []
    }
}
