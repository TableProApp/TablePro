//
//  ConnectionWorkspaceHandoff.swift
//  TablePro
//

import Foundation

/// Carries a live `ConnectionWorkspace` from the window it is leaving to the one being built for
/// it, so Open in New Window moves the connection rather than reopening it.
///
/// Rebuilding it in the new window would mean a second `SessionStateFactory.create`, and everything
/// the user has in that connection lives on the state it would replace: the open tabs, the change
/// manager holding unsaved cell edits, the coordinator, and the undo stack. The workspace is handed
/// over whole instead, keyed by the payload the new window is created with, mirroring how
/// `SessionStateFactory.registerPending` hands a freshly built state to a window that does not
/// exist yet.
@MainActor
internal enum ConnectionWorkspaceHandoff {
    private static var pending: [UUID: ConnectionWorkspace] = [:]

    internal static func register(_ workspace: ConnectionWorkspace, for payloadId: UUID) {
        pending[payloadId] = workspace
    }

    internal static func consume(for payloadId: UUID) -> ConnectionWorkspace? {
        pending.removeValue(forKey: payloadId)
    }

    /// A window that failed to build never consumes its handoff, and the workspace it was carrying
    /// is the user's open work. Returning it lets the caller put it back where it came from.
    @discardableResult
    internal static func reclaim(for payloadId: UUID) -> ConnectionWorkspace? {
        pending.removeValue(forKey: payloadId)
    }
}
