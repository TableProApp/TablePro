//
//  ConnectionWorkspace.swift
//  TablePro
//

import AppKit
import Combine
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

    /// Adopting a session is the first moment a connection names a container, and the container it
    /// lands on has to be recorded like any other: it is the entry the user leaves behind when they
    /// switch, and an entry nobody recorded is one that disappears the moment they do.
    internal var session: ConnectionSession? {
        didSet { recordBrowsedContainer() }
    }
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

    /// The containers this connection has open, one connections-strip entry each.
    ///
    /// A container is open from the moment the user browses to it until they close its entry, which
    /// is the only vocabulary a switcher can have: membership used to be derived from what the tabs
    /// were using, so a database with nothing open in it was listed only while the browse cursor
    /// stood on it, and moving off it deleted its entry. Clicking one entry of the strip therefore
    /// took another entry away, and with the strip down to a single entry the whole strip hid
    /// itself under the pointer.
    ///
    /// It lives here because a workspace is the one object whose lifetime is exactly a connection's
    /// stay in the app: `moveToNewWindow` hands this instance to the new window rather than building
    /// another, a disconnect keeps it while the coordinator underneath is torn down, and only
    /// closing the connection releases it.
    internal private(set) var openedContainers: Set<String> = []

    private var browseCancellable: AnyCancellable?
    private var statusCancellable: AnyCancellable?
    private var tabsCancellable: AnyCancellable?

    /// Set before `teardown` clears anything. Releasing the workspace writes `session = nil`, whose
    /// observer would otherwise record the container all over again from the session the manager has
    /// not dropped yet, and publish from a workspace no window hosts any more.
    private var isReleased = false

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
        observeBrowsedContainer()
        recordBrowsedContainer()
    }

    /// Both events, because either can be the first to name a container: a connect settles the one
    /// the session lands on, and every switch after that names the next. Recording the container the
    /// connection is on at the time keeps the entry the user is leaving, which is the whole point of
    /// the set.
    private func observeBrowsedContainer() {
        browseCancellable = AppEvents.shared.browseContainerChanged
            .filter { [connectionId] changed in changed == connectionId }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.recordBrowsedContainer()
            }
        statusCancellable = AppEvents.shared.connectionStatusChanged
            .filter { [connectionId] change in change.connectionId == connectionId }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.recordBrowsedContainer()
            }
        /// Tabs open containers too, and a window restoring its tabs opens several without browsing
        /// to any of them. Reading them only where the strip is built would lose them the moment the
        /// coordinator goes: a disconnect empties `tabManager`, and the containers those tabs held
        /// would leave the strip with them.
        tabsCancellable = AppEvents.shared.workspaceTabsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.recordTabContainers()
            }
    }

    private func recordBrowsedContainer() {
        guard !isReleased else { return }
        guard let container = WorkspaceRailStore.browsedWorkspace(for: connectionId)?.container else { return }
        openContainer(container)
    }

    private func recordTabContainers() {
        guard !isReleased, let type = connection?.type else { return }
        let target = PluginManager.shared.containerSwitchTarget(for: type)
        let held = WorkspaceAnchoring.containers(
            in: sessionState?.coordinator.tabManager.tabs ?? [],
            target: target
        )
        for container in held {
            openContainer(container)
        }
    }

    /// Publishes on insert rather than letting the strip work the change out for itself. Every rail
    /// listens to the same events this does, and Combine delivers them in subscription order, so a
    /// rail that reloaded first would list the set as it was a moment ago. An event of its own is
    /// what makes the order stop mattering.
    internal func openContainer(_ container: String) {
        guard !isReleased, !container.isEmpty, openedContainers.insert(container).inserted else { return }
        AppEvents.shared.connectionWindowsChanged.send()
    }

    internal func closeContainer(_ container: String) {
        guard openedContainers.remove(container) != nil else { return }
        AppEvents.shared.connectionWindowsChanged.send()
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
        isReleased = true
        browseCancellable = nil
        statusCancellable = nil
        tabsCancellable = nil
        openedContainers = []
        panes.teardown()
        rightPanelState?.teardown()
        rightPanelState = nil
        sessionState?.coordinator.teardown()
        sessionState = nil
        session = nil
        undoManager.removeAllActions()
    }
}
