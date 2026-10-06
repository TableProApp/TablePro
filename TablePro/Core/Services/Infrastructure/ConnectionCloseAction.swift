//
//  ConnectionCloseAction.swift
//  TablePro
//

import AppKit
import Foundation

/// The one path a user-requested connection close takes, whatever surface asked for it. A peer of
/// `ConnectionDisconnectAction` and of `WorkspaceCloseAction`, and the three are deliberately
/// different: Disconnect ends the session and leaves the connection in place to reconnect, closing
/// an entry takes one container of a connection, and this ends the connection and every entry it
/// has.
///
/// The strip used to send all three of its close routes here, because an entry had no lifetime of
/// its own: it was derived from the tabs, so a close scoped to one container left the row it was
/// invoked on exactly where it was, and the command read as doing nothing. An entry is now open
/// until it is closed, so a close on one takes that container and `WorkspaceCloseAction` owns it;
/// this is what a connection's last entry closes to, and what File > Close Connection runs.
@MainActor
internal enum ConnectionCloseAction {
    internal enum Decision: Equatable {
        case closeImmediately
        case confirmEndingTransaction
        case confirmUnsavedWork
    }

    /// Pure so the case that used to fail silently is pinned by a test: a connection with no session
    /// has nothing to lose, and asking about it produced an alert nobody could answer.
    /// Saves in every window hosting the connection, not only the one that answered first. Each
    /// coordinator can save just its own selected tab's live work, so a Save that reached one of
    /// them left the other window's grid edits behind and closed over them.
    private static func saveEveryWindowsWork(
        across coordinators: [MainContentCoordinator],
        fallback: MainContentCoordinator?
    ) async -> Bool {
        let targets = coordinators.isEmpty ? [fallback].compactMap { $0 } : coordinators
        for coordinator in targets {
            guard await coordinator.commandActions?.saveSelectedTabWork() == true else { return false }
        }
        return !targets.isEmpty
    }

    /// The transaction is asked about before unsaved work, whose Save writes at once: a Cancel on the
    /// transaction after it would keep the connection open with that write already made.
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

    internal static func close(connectionId: UUID) async {
        /// Every window hosting the connection. A tab torn off into its own window keeps its live
        /// grid and structure edits in that window's coordinator, and asking only the first one
        /// reported the connection as safe to close over work nobody had been shown.
        let coordinators = WindowManager.shared.coordinators(for: connectionId)
        let coordinator = coordinators.first ?? WindowManager.shared.coordinator(for: connectionId)
        /// Read at each decision, not once: the window stays editable while the transaction state
        /// and the alert are awaited.
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

        /// Shown, then asked. A data-loss alert over a connection the user cannot see names work
        /// they have no way to look at before answering. Revealing switches the window to it, so an
        /// answer that closes nothing puts the user back where they were: a close that leaves them
        /// on another connection, with its entry still in the strip, reads as a switch.
        let wasShowing = WindowManager.shared.shownConnection(besides: connectionId)
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
            WindowManager.shared.closeWindow(for: connectionId)
            return
        }

        let presentingWindow = reveal(connectionId: connectionId)
        switch await AlertHelper.confirmSaveChanges(
            message: String(localized: "Your changes will be lost if you don't save them."),
            window: presentingWindow
        ) {
        case .save:
            /// Save closes too, once the save has actually landed. It used to start the save and
            /// stop there, so the connection the user asked to close stayed open.
            guard await saveEveryWindowsWork(across: coordinators, fallback: coordinator) else {
                WindowManager.shared.show(wasShowing, inWindowHosting: connectionId)
                break
            }
            WindowManager.shared.closeWindow(for: connectionId)
        case .dontSave:
            WindowManager.shared.closeWindow(for: connectionId)
        case .cancel:
            WindowManager.shared.show(wasShowing, inWindowHosting: connectionId)
        }
    }

    /// `hasAnyUnsavedWork` is coordinator state, so it answers for a connection whose content has
    /// never been on screen. Acting on that answer needs the connection in front of the user first.
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
