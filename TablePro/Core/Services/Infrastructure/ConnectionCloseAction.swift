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
        case confirmUnsavedWork
    }

    /// Pure so the case that used to fail silently is pinned by a test: a connection with no session
    /// has nothing to lose, and asking about it produced an alert nobody could answer.
    internal static func decision(hasSession: Bool, hasUnsavedWork: Bool) -> Decision {
        guard hasSession, hasUnsavedWork else { return .closeImmediately }
        return .confirmUnsavedWork
    }

    internal static func close(connectionId: UUID) async {
        let coordinator = WindowManager.shared.coordinator(for: connectionId)
        let decision = decision(
            hasSession: coordinator != nil,
            hasUnsavedWork: coordinator?.hasAnyUnsavedWork() ?? false
        )
        guard decision == .confirmUnsavedWork else {
            WindowManager.shared.closeWindow(for: connectionId)
            return
        }

        /// Shown, then asked. A data-loss alert over a connection the user cannot see names work
        /// they have no way to look at before answering. Revealing switches the window to it, so an
        /// answer that closes nothing puts the user back where they were: a close that leaves them
        /// on another connection, with its entry still in the strip, reads as a switch.
        let wasShowing = WindowManager.shared.shownConnection(besides: connectionId)
        let presentingWindow = reveal(connectionId: connectionId)
        switch await AlertHelper.confirmSaveChanges(
            message: String(localized: "Your changes will be lost if you don't save them."),
            window: presentingWindow
        ) {
        case .save:
            /// Save closes too, once the save has actually landed. It used to start the save and
            /// stop there, so the connection the user asked to close stayed open.
            guard await coordinator?.commandActions?.saveSelectedTabWork() == true else {
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
