//
//  ConnectionCloseAction.swift
//  TablePro
//

import AppKit
import Foundation

// Disconnect keeps the connection to reconnect, an entry close takes one container, this ends the connection and every entry.
@MainActor
internal enum ConnectionCloseAction {
    internal enum Decision: Equatable {
        case closeImmediately
        case confirmEndingTransaction
        case confirmUnsavedWork
    }

    // Every window hosting the connection, every tab in each: saving only the selected tab closed over the rest.
    private static func saveEveryWindowsWork(
        across coordinators: [MainContentCoordinator],
        fallback: MainContentCoordinator?
    ) async -> Bool {
        let targets = coordinators.isEmpty ? [fallback].compactMap { $0 } : coordinators
        for coordinator in targets {
            guard await coordinator.commandActions?.saveEveryTabsWork() == true else { return false }
        }
        return !targets.isEmpty
    }

    private static func unsavedWorkMessage(across coordinators: [MainContentCoordinator]) -> String {
        let keepsTabsOpen = coordinators.contains { coordinator in
            coordinator.commandActions?.holdsWorkOnlyItsTabCanSave(among: coordinator.tabManager.tabs) == true
        }
        return MainContentCommandActions.unsavedWorkMessage(keepsTabsOpen: keepsTabsOpen)
    }

    // The transaction is asked before unsaved work, whose Save writes at once.
    internal static func decision(hasSession: Bool, holdsTransaction: Bool, hasUnsavedWork: Bool) -> Decision {
        guard hasSession else { return .closeImmediately }
        if holdsTransaction { return .confirmEndingTransaction }
        return hasUnsavedWork ? .confirmUnsavedWork : .closeImmediately
    }

    internal static func transactionMessage(for databases: [String]) -> String? {
        guard let first = databases.first else { return nil }
        guard databases.count > 1 else {
            return String(
                format: String(localized: "The database “%@” has an open transaction. Closing rolls it back and discards its uncommitted changes."),
                first
            )
        }
        return String(
            format: String(localized: "These databases have open transactions: %@. Closing rolls them back and discards their uncommitted changes."),
            ListFormatter.localizedString(byJoining: databases.map { "“\($0)”" })
        )
    }

    internal static func close(connectionId: UUID, registry: RunningWorkRegistry = .shared) async {
        // Every window hosting the connection: a torn-off tab keeps its edits in its own coordinator.
        let coordinators = WindowManager.shared.coordinators(for: connectionId)
        let coordinator = coordinators.first ?? WindowManager.shared.coordinator(for: connectionId)
        // Read at each decision: the window stays editable while the alerts are awaited.
        let hasUnsavedWork = {
            coordinators.contains { $0.hasAnyUnsavedWork() }
                || (coordinators.isEmpty && coordinator?.hasAnyUnsavedWork() == true)
        }
        let holding = await DatabaseManager.shared.databasesHoldingTransaction(for: connectionId)
        var decision = decision(
            hasSession: coordinator != nil,
            holdsTransaction: !holding.isEmpty,
            hasUnsavedWork: hasUnsavedWork()
        )

        // Shown, then asked; a close that closes nothing puts the user back where they were.
        let wasShowing = WindowManager.shared.shownConnection(besides: connectionId)
        let work = registry.items(in: .connection(connectionId))
        var hasAnsweredForWork = false
        // With nothing unsaved, one alert names the work and any open transaction.
        if !work.isEmpty, !hasUnsavedWork(), let prompt = RunningWorkPrompt.make(
            action: .close,
            work: work,
            otherLosses: RunningWorkPrompt.transactionLines(for: holding)
        ) {
            guard await RunningWorkApproval.confirm(prompt, window: reveal(connectionId: connectionId)) else {
                WindowManager.shared.show(wasShowing, inWindowHosting: connectionId)
                return
            }
            hasAnsweredForWork = true
            // Another window on the connection stayed editable while the alert was up.
            decision = Self.decision(hasSession: coordinator != nil, holdsTransaction: false, hasUnsavedWork: hasUnsavedWork())
        }
        if decision == .confirmEndingTransaction, let coordinator, let message = transactionMessage(for: holding) {
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(format: String(localized: "Close the connection “%@”?"), coordinator.connection.name),
                message: message,
                confirmButton: String(localized: "Close"),
                window: reveal(connectionId: connectionId)
            )
            guard confirmed else {
                WindowManager.shared.show(wasShowing, inWindowHosting: connectionId)
                return
            }
            decision = Self.decision(hasSession: true, holdsTransaction: false, hasUnsavedWork: hasUnsavedWork())
        }
        guard decision == .confirmUnsavedWork else {
            // The edits were saved meanwhile, so the work still needs its own answer.
            if !hasAnsweredForWork, let prompt = RunningWorkPrompt.make(action: .close, work: work) {
                guard await RunningWorkApproval.confirm(prompt, window: reveal(connectionId: connectionId)) else {
                    WindowManager.shared.show(wasShowing, inWindowHosting: connectionId)
                    return
                }
            }
            registry.cancel(work)
            WindowManager.shared.closeWindow(for: connectionId)
            return
        }

        // Work is stopped only once the close is certain: a cancelled or failed save keeps it running.
        let presentingWindow = reveal(connectionId: connectionId)
        let targets = coordinators.isEmpty ? [coordinator].compactMap { $0 } : coordinators
        switch await AlertHelper.confirmSaveChanges(
            message: RunningWorkPrompt.saveMessage(
                unsavedWorkMessage(across: targets),
                action: .close,
                alsoStopping: hasAnsweredForWork ? [] : work
            ),
            window: presentingWindow
        ) {
        case .save:
            // Save closes too, once the save has landed.
            guard await saveEveryWindowsWork(across: coordinators, fallback: coordinator) else {
                WindowManager.shared.show(wasShowing, inWindowHosting: connectionId)
                break
            }
            registry.cancel(work)
            WindowManager.shared.closeWindow(for: connectionId)
        case .dontSave:
            registry.cancel(work)
            WindowManager.shared.closeWindow(for: connectionId)
        case .cancel:
            WindowManager.shared.show(wasShowing, inWindowHosting: connectionId)
        }
    }

    // The answer can name a connection never on screen, so it is brought forward first.
    @discardableResult
    private static func reveal(connectionId: UUID) -> NSWindow? {
        guard let window = WindowManager.shared.window(for: connectionId),
              let host = window.contentViewController as? MainSplitViewController else { return nil }
        if let group = window.tabGroup, group.selectedWindow !== window {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        host.workspaces.select(connectionId)
        return window
    }
}
