//
//  ConnectionWorkspace.swift
//  TablePro
//

import AppKit
import Foundation

/// Everything a window needs to present one connection. `MainSplitViewController` used to hold
/// these as scalar fields because a window served exactly one connection for its whole life;
/// they live here so a window can hold several and show one at a time.
@MainActor
internal final class ConnectionWorkspace {
    internal let connectionId: UUID
    internal let payload: EditorTabPayload?
    internal let autoConnect: Bool

    internal var payloadConnection: DatabaseConnection?
    internal var session: ConnectionSession?
    internal var sessionState: SessionStateFactory.SessionState?
    internal var rightPanelState: RightPanelState?
    internal var attemptToken: UUID?
    internal var phase: ConnectionWindowPhase

    /// Each workspace owns its undo stack. Routing through `NSWindow.undoManager` was correct
    /// while a window meant one connection; sharing one window between several would let an
    /// undo in one connection roll back an edit made in another.
    internal let undoManager: UndoManager

    internal init(
        connectionId: UUID,
        payload: EditorTabPayload?,
        autoConnect: Bool,
        payloadConnection: DatabaseConnection?,
        session: ConnectionSession?,
        sessionState: SessionStateFactory.SessionState?,
        rightPanelState: RightPanelState?,
        phase: ConnectionWindowPhase
    ) {
        self.connectionId = connectionId
        self.payload = payload
        self.autoConnect = autoConnect
        self.payloadConnection = payloadConnection
        self.session = session
        self.sessionState = sessionState
        self.rightPanelState = rightPanelState
        self.phase = phase
        self.undoManager = UndoManager()
    }

    internal var connection: DatabaseConnection? {
        payloadConnection ?? session?.connection
    }

    internal var retainsRestoreIntent: Bool {
        ConnectionWindowPhaseMachine.retainsRestoreIntent(phase: phase)
    }

    internal func teardown() {
        rightPanelState?.teardown()
        rightPanelState = nil
        sessionState?.coordinator.teardown()
        sessionState = nil
        session = nil
        undoManager.removeAllActions()
    }
}
