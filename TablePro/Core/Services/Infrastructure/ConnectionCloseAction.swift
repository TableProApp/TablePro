//
//  ConnectionCloseAction.swift
//  TablePro
//

import AppKit
import Foundation

/// The one path a user-requested connection close takes, whatever surface asked for it. A peer of
/// `ConnectionDisconnectAction`, and the two are deliberately different: Disconnect ends the
/// session and leaves the connection in place to reconnect, Close ends the connection.
///
/// The rail used to offer this as "Close Workspace", wired to the tab strip's bulk-close family, so
/// it closed a subset of one connection's tabs and left the row it was invoked on exactly where it
/// was. No platform or competitor precedent puts that scope on a list of open sessions: the HIG has
/// no close verb for a sidebar row at all, the one app shipping the literal string is Xcode's File
/// menu where it means the whole project session, and Finder's Locations rows, the true analogue of
/// a list of live remote sessions, end the session and drop the row.
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
        /// they have no way to look at before answering.
        let presentingWindow = reveal(connectionId: connectionId)
        switch await AlertHelper.confirmSaveChanges(
            message: String(localized: "Your changes will be lost if you don't save them."),
            window: presentingWindow
        ) {
        case .save:
            /// Save closes too, once the save has actually landed. It used to start the save and
            /// stop there, so the connection the user asked to close stayed open.
            guard await coordinator?.commandActions?.saveSelectedTabWork() == true else { break }
            WindowManager.shared.closeWindow(for: connectionId)
        case .dontSave:
            WindowManager.shared.closeWindow(for: connectionId)
        case .cancel:
            break
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
