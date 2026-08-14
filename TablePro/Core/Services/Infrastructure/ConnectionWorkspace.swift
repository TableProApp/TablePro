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

    /// This connection's own view tree, built once and kept. The window shows one workspace's panes
    /// at a time by swapping which of these is the split items' child.
    internal let panes = WorkspacePanes()

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

    /// Payloads that arrived before this workspace had a session to open them in. A connect can
    /// take seconds, and a table asked for in the meantime has to survive the wait rather than
    /// be dropped.
    private var pendingPayloads: [EditorTabPayload] = []

    internal var connection: DatabaseConnection? {
        payloadConnection ?? session?.connection
    }

    /// Opens what the payload names. Held until the session exists if the connection is still
    /// being established.
    internal func open(_ payload: EditorTabPayload) {
        guard let sessionState, let connection else {
            pendingPayloads.append(payload)
            return
        }
        EditorTabOpener.apply(
            payload,
            to: sessionState.tabManager,
            connection: connection,
            toolbarState: sessionState.toolbarState
        )
    }

    /// Runs once a session has been adopted. The payload the workspace was created with is
    /// already applied by `SessionStateFactory`, so only the ones that arrived after it are here.
    internal func drainPendingPayloads() {
        guard !pendingPayloads.isEmpty else { return }
        let queued = pendingPayloads
        pendingPayloads.removeAll()
        for payload in queued {
            open(payload)
        }
    }

    internal var retainsRestoreIntent: Bool {
        ConnectionWindowPhaseMachine.retainsRestoreIntent(phase: phase)
    }

    /// The panes go down with the rest of it. They retain the SwiftUI tree, which retains the
    /// coordinator this tears down, and a coordinator only leaves the app-wide registry on deinit.
    internal func teardown() {
        panes.teardown()
        rightPanelState?.teardown()
        rightPanelState = nil
        sessionState?.coordinator.teardown()
        sessionState = nil
        session = nil
        undoManager.removeAllActions()
    }
}
