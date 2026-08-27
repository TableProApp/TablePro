//
//  MainSplitViewController.swift
//  TablePro
//
//  NSSplitViewController replacing NavigationSplitView for native sidebar/inspector.
//  Owns session state, manages three panes (sidebar, detail, inspector), and
//  serves as window.contentViewController so .toggleSidebar and
//  .sidebarTrackingSeparator work via the responder chain.
//

import AppKit
import Combine
import os
import SwiftUI

@MainActor
internal final class MainSplitViewController: NSSplitViewController, InspectorVisibilityProxy {
    nonisolated private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    // MARK: - Payload & Session

    /// The connections this window hosts. A window used to answer this with its own identity,
    /// which could only ever name one, so every field below reads through the selected entry.
    let workspaces = ConnectionWorkspaceRegistry()

    var payload: EditorTabPayload? { workspaces.selected?.payload }

    /// Re-read when the connection record changes, so a rename reaches the window's name and
    /// the connecting screen instead of freezing whatever the record said at creation.
    var payloadConnection: DatabaseConnection? {
        get { workspaces.selected?.payloadConnection }
        set { workspaces.selected?.payloadConnection = newValue }
    }

    private var currentSession: ConnectionSession? {
        get { workspaces.selected?.session }
        set { workspaces.selected?.session = newValue }
    }

    private var sessionState: SessionStateFactory.SessionState? {
        get { workspaces.selected?.sessionState }
        set { workspaces.selected?.sessionState = newValue }
    }

    private var rightPanelState: RightPanelState? {
        get { workspaces.selected?.rightPanelState }
        set { workspaces.selected?.rightPanelState = newValue }
    }

    var autoConnect: Bool { workspaces.selected?.autoConnect ?? false }

    var attemptToken: UUID? {
        get { workspaces.selected?.attemptToken }
        set { workspaces.selected?.attemptToken = newValue }
    }

    var phase: ConnectionWindowPhase {
        get { workspaces.selected?.phase ?? .idle }
        set {
            guard let connectionId = workspaces.selectedConnectionId else { return }
            transition(to: newValue, for: connectionId)
        }
    }

    var windowTitle: String {
        didSet {
            let sanitized = WindowTitleResolver.sanitizeTitle(previous: oldValue, candidate: windowTitle)
            if sanitized != windowTitle {
                windowTitle = sanitized
            }
            view.window?.title = windowTitle
        }
    }

    var windowSubtitle: String {
        didSet { view.window?.subtitle = windowSubtitle }
    }

    // MARK: - Split View Items

    private var sidebarSplitItem: NSSplitViewItem!
    private var detailSplitItem: NSSplitViewItem!
    private var inspectorSplitItem: NSSplitViewItem!

    private var navigationSidebar: NavigationSidebarViewController!
    /// Stable containers, one per split item. The pane they show is the selected workspace's own,
    /// so switching connection is a view swap and every other connection's tree stays built.
    private var detailPaneHost: WorkspacePaneHost!
    private var inspectorPaneHost: WorkspacePaneHost!

    /// The editor tab strip's band. It is a titlebar accessory rather than a split item, so it is
    /// owned here but installed on the window, and it follows the selected workspace the same way
    /// the two hosts above do.
    let tabStripAccessory = EditorTabStripAccessoryController()

    /// Re-armed each time it fires, and stale arms are dropped by comparing this against the
    /// generation captured when they registered.
    var tabStripObservationGeneration = 0

    /// `withObservationTracking` has no way to cancel a registration, so re-registering blindly
    /// leaves one live arm per call behind until the next change wakes them all. These two say
    /// whether the live arm still watches the right tab manager, so a repeated call is free and
    /// only a workspace switch or a fired arm registers again.
    var tabStripObservationIsArmed = false
    var tabStripObservedManager: ObjectIdentifier?

    // MARK: - Panel Layout State

    /// One name for the window's split view, because one `NSSplitView` can only carry one.
    ///
    /// The name used to be derived from the selected connection, which stopped meaning anything
    /// once a window began hosting every connection: the widths a user set while one connection
    /// was selected were autosaved under whichever connection the name happened to name at the
    /// time. Per-connection widths are not reachable through `autosaveName` anyway, since assigning
    /// a name to a split view that has already laid out does not re-apply the saved frames.
    ///
    /// Never version this key to force a relayout. `NSSplitView` clamps a restored frame against
    /// the current minimums, so the sidebar simply widens to fit the rail. Bumping it instead
    /// throws away every saved sidebar width, inspector width and collapse state the user has,
    /// leaves the old keys orphaned in `UserDefaults`, and reads as a regression nobody asked for.
    private var splitAutosaveName: NSSplitView.AutosaveName {
        "com.TablePro.mainSplit"
    }

    // MARK: - Switcher Surfaces

    /// The window's one floating panel and the presenter that drives it, owned here rather than by
    /// a connection's coordinator.
    ///
    /// `QuickSwitcherPanelController` positions itself from its parent window's frame alone, so
    /// two of them over one window centre on the same point with neither able to see or dismiss
    /// the other. One per coordinator meant exactly that, once a window began hosting several
    /// connections. It also put Switch Connection, which lists every saved connection and needs
    /// nothing from the session, behind the session that had just gone away.
    let quickSwitcherPanel = QuickSwitcherPanelController()

    lazy var switcherPresenter = ToolbarSwitcherPresenter(panelController: quickSwitcherPanel)

    // MARK: - Toolbar

    private var toolbarOwner: MainWindowToolbar?

    /// The coordinator currently treated as this window's active one, so a workspace switch can
    /// hand over key-window state the same way AppKit would between windows.
    private weak var lastActiveCoordinator: MainContentCoordinator?

    // MARK: - Observers

    private var connectionStatusCancellable: AnyCancellable?
    private var railVisibilityCancellable: AnyCancellable?
    private var connectionUpdatedCancellable: AnyCancellable?

    // MARK: - Init

    init(
        payload: EditorTabPayload?,
        sessionState: SessionStateFactory.SessionState?,
        autoConnect: Bool = false,
        adopting workspace: ConnectionWorkspace? = nil
    ) {
        self.windowTitle = ""
        self.windowSubtitle = ""

        super.init(nibName: nil, bundle: nil)

        if let workspace {
            /// It arrives with its panes already built, by the controller it is leaving. Every
            /// closure in them calls back into that one, so they have to be produced again here
            /// even though nothing about the connection has changed.
            workspace.panes.invalidate()
            workspaces.insert(workspace)
        } else {
            adoptWorkspace(payload: payload, autoConnect: autoConnect)
        }

        /// AppKit renders a native tab's label even for a tab that is never activated, so the
        /// title has to be right at creation rather than at first appearance.
        applyWindowTitle()
    }

    /// Builds the workspace for one connection and hands it to the registry. A window reaches
    /// here once per connection it hosts, so nothing may assume it runs only at construction.
    @discardableResult
    internal func adoptWorkspace(payload: EditorTabPayload?, autoConnect: Bool) -> ConnectionWorkspace? {
        var resolvedSession: ConnectionSession?
        if let connectionId = payload?.connectionId {
            resolvedSession = DatabaseManager.shared.activeSessions[connectionId]
        } else if let currentId = DatabaseManager.shared.lastActiveSessionId {
            resolvedSession = DatabaseManager.shared.activeSessions[currentId]
        }

        guard let connectionId = payload?.connectionId ?? resolvedSession?.connection.id else { return nil }

        if let existing = workspaces.workspace(for: connectionId) {
            workspaces.select(connectionId)
            return existing
        }

        let resolvedConnection = DatabaseManager.shared.activeSessions[connectionId]?.connection
            ?? ConnectionStorage.shared.loadConnections().first { $0.id == connectionId }

        var state: SessionStateFactory.SessionState?
        var panelState: RightPanelState?
        if let session = resolvedSession {
            panelState = RightPanelState(connectionId: session.connection.id)
            if let payloadId = payload?.id,
               let pending = SessionStateFactory.consumePending(for: payloadId) {
                state = pending
                Self.lifecycleLogger.info(
                    "[open] MainSplitVC.adoptWorkspace consumed pending payloadId=\(payloadId, privacy: .public)"
                )
            } else {
                state = SessionStateFactory.create(connection: session.connection, payload: payload)
            }
        }

        /// Resolved through the same machine every later status event uses. Reading the driver
        /// directly adopted a connection as connected over a handle a reconnect had already given up
        /// on, and a monitor that has given up sends no further event to correct it.
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: resolvedSession == nil ? .idle : .connecting,
            session: ConnectionSessionSnapshot(
                exists: resolvedSession != nil,
                hasDriver: resolvedSession?.driver != nil,
                disconnectInfo: DatabaseManager.shared.disconnectReason(for: connectionId),
                liveness: resolvedSession?.liveness ?? .live
            ),
            ownsAttempt: false
        )

        let workspace = ConnectionWorkspace(
            connectionId: connectionId,
            payload: payload,
            autoConnect: autoConnect,
            payloadConnection: resolvedConnection,
            session: resolvedSession,
            sessionState: state,
            rightPanelState: panelState,
            phase: phase
        )
        let adopted = workspaces.insert(workspace)

        /// A workspace adopted into a window that is already on screen has to dial for itself.
        /// `viewWillAppear` is what starts the connect for the window's first workspace, and it
        /// runs once: every connection opened into that window afterwards reached the registry
        /// with its intent to connect recorded and nothing left to act on it, so picking a
        /// connection from the toolbar switcher landed on the not-connected pane with a Connect
        /// button the user had to press themselves. The guard is the lifecycle, not a special
        /// case: before the view loads there are no panes for a phase change to repaint.
        if isViewLoaded, view.window != nil {
            startActivationConnectIfNeeded()
        }
        return adopted
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainSplitViewController does not support NSCoder init")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.dividerStyle = .thin
        splitView.isVertical = true

        navigationSidebar = NavigationSidebarViewController()
        navigationSidebar.railController.host = self
        navigationSidebar.railController.onLayoutChange = { [weak self] _ in
            self?.navigationSidebar.applyRailWidth(animated: false)
            /// The row size is a setting, so the rail's own width changes under a sidebar already
            /// narrowed to it. Reapplying the clamp is what moves both thicknesses onto the new
            /// allowance rather than clipping the rail against the old one.
            self?.reapplySidebarClampIfNarrowed()
            self?.recomputeWindowMinSize()
        }
        sidebarSplitItem = NSSplitViewItem(sidebarWithViewController: navigationSidebar)
        sidebarSplitItem.canCollapse = true
        sidebarSplitItem.minimumThickness = Self.sidebarMinThickness
        sidebarSplitItem.maximumThickness = Self.sidebarMaxThickness
        addSplitViewItem(sidebarSplitItem)

        detailPaneHost = WorkspacePaneHost()
        detailSplitItem = NSSplitViewItem(viewController: detailPaneHost)
        detailSplitItem.minimumThickness = Self.resolveDetailMinimumThickness(for: payload?.tabType)
        detailSplitItem.holdingPriority = .defaultLow
        addSplitViewItem(detailSplitItem)

        inspectorPaneHost = WorkspacePaneHost()
        inspectorSplitItem = NSSplitViewItem(inspectorWithViewController: inspectorPaneHost)
        inspectorSplitItem.canCollapse = true
        inspectorSplitItem.minimumThickness = Self.inspectorMinThickness
        inspectorSplitItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        /// The inspector ships closed. Set before the autosave name, so a user who has opened it
        /// gets their own state restored over this one and a first run gets a closed inspector
        /// without anyone having to read AppKit's own autosave record to find out which it is.
        inspectorSplitItem.isCollapsed = true
        addSplitViewItem(inspectorSplitItem)

        navigationSidebar.railController.onEntryCountChange = { [weak self] count in
            self?.applyRailVisibility(workspaceCount: count)
        }

        /// The saved layout is restored before any phase-driven collapse, so the user's widths
        /// are already in the live layout. Uncollapsing then returns the pane to the size
        /// `NSSplitViewItem` remembers, rather than depending on a second restore.
        workspaces.onSelectionChange = { [weak self] _ in
            self?.applySelectedWorkspace()
        }

        /// A connection joining or leaving the window changes what every rail in the app lists,
        /// which is what this event is for. Which row is current is a separate question, answered
        /// by the rail reading its host back, so a selection change must not come through here.
        workspaces.onMembershipChange = {
            AppEvents.shared.connectionWindowsChanged.send()
        }

        restoreUserPaneLayout()
        syncSelectedPanes()
        showSelectedPanes()
        applyPaneChrome()
    }

    /// A divider dragged all the way in collapses the sidebar without going through
    /// `toggleSidebar(_:)`, so the toolbar has to be reconciled here too or its segment stays lit
    /// over a sidebar that is no longer on screen.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        recomputeWindowMinSize()
        toolbarOwner?.syncSidebarSelection()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard let window = view.window else { return }

        window.title = windowTitle
        window.subtitle = windowSubtitle

        if let sessionState {
            sessionState.coordinator.inspectorProxy = self
            sessionState.coordinator.splitViewController = self
            installToolbar(coordinator: sessionState.coordinator)
        }

        if let currentSession, sessionState != nil {
            navigationSidebar.objectBrowser.updateSidebarState(
                SharedSidebarState.forConnection(currentSession.connection.id)
            )
        }

        installObservers()
        recomputeWindowMinSize()
        window.recalculateKeyViewLoop()
        startActivationConnectIfNeeded()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        removeObservers()
    }

    // MARK: - Observers

    private func installObservers() {
        guard connectionStatusCancellable == nil else { return }
        connectionStatusCancellable = AppEvents.shared.connectionStatusChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleConnectionStatusChange()
            }
        railVisibilityCancellable = AppEvents.shared.workspaceRailVisibilityChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyRailVisibility(workspaceCount: WorkspaceRailStore.entries.count)
            }
        connectionUpdatedCancellable = AppEvents.shared.connectionUpdated
            .receive(on: RunLoop.main)
            .sink { [weak self] changedId in
                self?.handleConnectionRecordChange(changedId)
            }
        handleConnectionStatusChange()
        applyRailVisibility(workspaceCount: WorkspaceRailStore.entries.count)
    }

    private func removeObservers() {
        connectionStatusCancellable = nil
        railVisibilityCancellable = nil
        connectionUpdatedCancellable = nil
    }

    /// `nil` is the documented bulk-update payload, so it has to repaint too.
    ///
    /// The toolbar takes the record here and not from its panes: `ConnectionToolbarState` is built
    /// once per session and `refreshPanes` only reassigns SwiftUI root views, so without this line
    /// the titlebar kept the name and colour the connection had when it was opened (#2398).
    private func handleConnectionRecordChange(_ changedId: UUID?) {
        let stored = ConnectionStorage.shared.loadConnections()
        var repaint = false
        for workspace in workspaces.workspaces {
            let connectionId = workspace.connectionId
            guard changedId == nil || changedId == connectionId else { continue }
            guard let record = stored.first(where: { $0.id == connectionId })
                ?? DatabaseManager.shared.activeSessions[connectionId]?.connection else { continue }
            workspace.payloadConnection = record
            workspace.sessionState?.toolbarState.update(from: record)
            /// The one repaint the render key cannot decide, so the only one that skips it. Deleting
            /// a connection whose session is still open purges the per-connection registries the
            /// panes hold without changing the record they were built from, and a pane left holding
            /// the purged `SharedSidebarState` stops seeing what the rest of the window does to the
            /// newly registered one.
            refreshPanes(of: workspace)
            if workspaces.selectedConnectionId == connectionId { repaint = true }
        }
        guard repaint else { return }
        applyWindowTitle()
    }

    // MARK: - Toolbar

    /// Only ever called with a live coordinator. The window keeps one toolbar for its whole life
    /// and points it at whichever connection it is showing, so this builds the owner once and
    /// repoints it afterwards. `NSWindow.toolbar` is assigned only when it differs, because
    /// assigning an already-built toolbar still makes AppKit rebuild the titlebar hierarchy.
    func installToolbar(coordinator: MainContentCoordinator) {
        guard let window = view.window else { return }
        let owner = toolbarOwner ?? MainWindowToolbar()
        toolbarOwner = owner
        owner.subject.windowController = self
        /// Pointed at the connection before the toolbar reaches the window, so the delegate builds
        /// its items with a subject already in place and nothing has to be rebuilt afterwards.
        owner.repoint(to: coordinator)
        if window.toolbar !== owner.managedToolbar {
            window.toolbar = owner.managedToolbar
        }
    }

    /// The window's toolbar goes too. Dropping only the owner left the built `NSToolbar` on the
    /// window with item views still pointing at the coordinator that was just released.
    func invalidateToolbar() {
        toolbarOwner?.invalidate()
        toolbarOwner = nil
        if isViewLoaded { view.window?.toolbar = nil }
    }

    // MARK: - Connection Status

    /// Every hosted connection reconciles, not only the one on screen. A background workspace
    /// that loses its session still has to reach the right phase, or switching to it later
    /// would show content for a connection that is already gone.
    private func handleConnectionStatusChange() {
        defer { toolbarOwner?.syncSidebarSelection() }
        for workspace in workspaces.workspaces {
            reconcileStatus(of: workspace)
        }
    }

    private func reconcileStatus(of workspace: ConnectionWorkspace) {
        let sid = workspace.connectionId
        let session = DatabaseManager.shared.activeSessions[sid]
        let snapshot = ConnectionSessionSnapshot(
            exists: session != nil,
            hasDriver: session?.driver != nil,
            disconnectInfo: DatabaseManager.shared.disconnectReason(for: sid),
            wasDisconnectedByUser: DatabaseManager.shared.wasDisconnectedByUser(sid),
            liveness: session?.liveness ?? .live
        )
        let nextPhase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: workspace.phase,
            session: snapshot,
            ownsAttempt: workspace.attemptToken != nil
        )
        /// Nothing here paints. The panes are built from the phase, so they can only be built once
        /// the phase is final, and `transition(to:for:)` is where that happens. Adopting a session
        /// bumps the workspace's session revision, which is what tells the sync that a session
        /// whose phase did not move still has to be redrawn.
        ///
        /// `isContentViewEquivalent` answers whether the views would draw the same, not whether it
        /// is the same session: it excludes the driver, the effective connection and the cached
        /// password on purpose. A connection arriving back at `.connected` therefore adopts whatever
        /// the manager now holds even when the two would draw alike, or a tunnel recovery would
        /// leave the workspace holding the driver it just disconnected, and that driver's cached
        /// credentials, until something else replaced the session.
        if nextPhase == .connected, let session {
            let drawsTheSame = workspace.session?.isContentViewEquivalent(to: session) ?? false
            if !drawsTheSame || workspace.phase != nextPhase {
                adoptSession(session, into: workspace)
            }
        } else if workspace.phase == .connected, nextPhase != .connected, !snapshot.exists {
            releaseSession(workspace)
        }

        transition(to: nextPhase, for: sid)
    }

    private func adoptSession(_ session: ConnectionSession, into workspace: ConnectionWorkspace) {
        workspace.session = session

        if workspace.rightPanelState == nil {
            workspace.rightPanelState = RightPanelState(connectionId: session.connection.id)
        }
        if workspace.sessionState == nil {
            let state = SessionStateFactory.create(connection: session.connection, payload: workspace.payload)
            workspace.sessionState = state
            state.coordinator.inspectorProxy = self
            state.coordinator.splitViewController = self
            if workspaces.selectedConnectionId == workspace.connectionId {
                installToolbar(coordinator: state.coordinator)
            }
        }
        workspace.drainPendingPayloads()
    }

    /// Only called once the session entry is gone. A session that still exists without a driver
    /// is reconnecting, and tearing the coordinator down for that takes the user's open tabs and
    /// unsaved query edits with it over a network blip that repairs itself seconds later.
    private func releaseSession(_ workspace: ConnectionWorkspace) {
        Self.lifecycleLogger.info(
            "[close] MainSplitVC session removed connId=\(workspace.connectionId, privacy: .public)"
        )
        workspace.rightPanelState?.teardown()
        workspace.rightPanelState = nil
        /// The toolbar goes with the coordinator it was built for. `MainWindowToolbar.coordinator`
        /// is weak, so tearing the coordinator down while the toolbar stayed installed left the
        /// delegate answering nil for every identifier it advertises. `autosavesConfiguration` is
        /// on, so the next vend AppKit asks for, opening Customize Toolbar or dragging an item,
        /// would have pruned those items from the user's saved configuration for good. Comparing
        /// the coordinator itself rather than which workspace is on screen keeps this exact when a
        /// background workspace loses its session.
        let releasedCoordinator = workspace.sessionState?.coordinator
        workspace.sessionState?.coordinator.teardown()
        workspace.sessionState = nil
        workspace.session = nil
        if let releasedCoordinator, toolbarOwner?.coordinator === releasedCoordinator {
            toolbarOwner?.repoint(to: nil)
        }
        /// The panes are rebuilt rather than dropped: the workspace stays in the registry so it can
        /// render its own phase, and its content view is now the not-connected pane. Leaving the
        /// old tree mounted would keep the torn-down coordinator alive through it. Clearing the
        /// session above bumped the revision, so the sync at the end of the transition this is part
        /// of is what does it, after the phase has stopped saying `.connected`.
        if isShowing(workspace) {
            navigationSidebar.objectBrowser.updateSidebarState(nil)
        }
    }

    /// Switching workspace repaints the window in place. The rail used to raise a different
    /// window instead, which is what made several connections mean several windows.
    internal func applySelectedWorkspace() {
        /// Switching workspace is this window's key-window change as far as a coordinator is
        /// concerned. Only the selected one receives the real `windowDidBecomeKey`, so without
        /// this the outgoing connection keeps `isKeyWindow` true and never schedules the eviction
        /// that frees its row buffers.
        let incoming = workspaces.selected?.sessionState?.coordinator
        if lastActiveCoordinator !== incoming {
            lastActiveCoordinator?.handleWindowDidResignKey()
            incoming?.handleWindowDidBecomeKey()
            lastActiveCoordinator = incoming
        }

        /// A workspace with no session has no toolbar of its own, and the outgoing one's is not a
        /// stand-in: it names the other connection, its database and its schema, and every one of
        /// its buttons still acts on that connection. Switching to a connection that has not come
        /// up yet showed the previous connection's engine icon and schema over a pane that said
        /// the new one was not connected. A plain titlebar is what a sessionless window shows.
        if let coordinator = workspaces.selected?.sessionState?.coordinator {
            coordinator.inspectorProxy = self
            coordinator.splitViewController = self
            installToolbar(coordinator: coordinator)
        } else {
            /// Pointed at nothing rather than torn off the window. Every item validates to disabled
            /// with no subject, and leaving the toolbar in place keeps AppKit from rebuilding the
            /// titlebar twice for a switch the user experiences as one.
            toolbarOwner?.repoint(to: nil)
        }

        /// A workspace can reach the window already built and never repainted: `adoptWorkspace`
        /// hands one over with a live session and no phase change to follow, so its panes still
        /// held the empty view they were constructed with and the connection opened blank. This
        /// costs a key comparison when nothing has moved, which is what the record is for.
        syncSelectedPanes()
        showSelectedPanes()
        applyDetailMinimumThicknessForSelection()
        applyPaneChrome()
        applyWindowTitle()

        /// Only this window's rail moved, and only its highlight. Broadcasting instead made every
        /// rail in the app rebuild its whole entry list to answer a question none of them asked.
        navigationSidebar?.railController.refreshSelection()
    }

    private func applyPhase() {
        syncSelectedPanes()
        applyPaneChrome()
        applyWindowTitle()
        SessionRecoveryTracker.sync()
    }

    /// Repainted on every phase change for the same reason the panes are. Leaving it out is
    /// what let a window keep the name of a table it had stopped showing after the session
    /// underneath it went away.
    internal func applyWindowTitle() {
        let resolved = WindowTitleResolver.resolveWindow(
            pane: currentPane,
            connection: paneConnection,
            tab: sessionState?.tabManager.selectedTab,
            hasTabs: !(sessionState?.tabManager.tabs.isEmpty ?? true),
            queryLanguageName: paneConnection.map { PluginManager.shared.queryLanguageName(for: $0.type) } ?? nil
        )
        windowTitle = resolved.title
        windowSubtitle = resolved.subtitle
    }

    internal func transition(to next: ConnectionWindowPhase) {
        phase = next
    }

    /// A window now hosts several connections, so a phase change has to name the one it belongs to,
    /// and this is the only place a phase is written outside a window close.
    ///
    /// The sync runs whether or not this workspace is the one on screen, because a background one
    /// owns persistent panes that would otherwise keep the phase they last rendered (#2545), and
    /// whether or not the phase moved, because a session can be replaced under an unchanged one as
    /// a database switch does. Only the window's own chrome is gated on the phase moving.
    internal func transition(to next: ConnectionWindowPhase, for connectionId: UUID) {
        guard let workspace = workspaces.workspace(for: connectionId) else { return }
        let phaseChanged = workspace.phase != next
        workspace.phase = next
        syncPanes(of: workspace)
        guard phaseChanged else { return }
        if workspaces.selectedConnectionId == connectionId {
            applyPaneChrome()
            applyWindowTitle()
        }
        SessionRecoveryTracker.sync()
    }

    internal func refreshFromActiveSessions() {
        handleConnectionStatusChange()
    }

    /// Closing the window closes every connection it hosts, so each workspace has to reach
    /// `.closing` on its own. Leaving a background one behind would let it keep a restore
    /// intent for a window that no longer exists.
    internal func markWindowClosing() {
        /// The panel is an independent floating `NSPanel` with no parent-child relationship to the
        /// window, so nothing takes it down with the window that opened it. The toolbar used to do
        /// this on the way past, through the connection whose coordinator owned the presenter; the
        /// window owns it now and can present it with no coordinator at all, which is exactly the
        /// case that left a chooser on screen over a window that had gone.
        switcherPresenter.dismiss()
        for workspace in workspaces.workspaces {
            workspace.phase = ConnectionWindowPhaseMachine.onWindowClosing(phase: workspace.phase)
        }
        applyPhase()
    }

    internal var retainsRestoreIntent: Bool {
        workspaces.workspaces.contains { $0.retainsRestoreIntent }
    }

    internal var connectionIdsRetainingRestoreIntent: [UUID] {
        workspaces.workspaces.filter(\.retainsRestoreIntent).map(\.connectionId)
    }

    // MARK: - Pane Construction

    /// Rebuilds one connection's panes into its own hosting controllers, whether or not it is the
    /// one on screen, and records what they were built from. This is the only place all four panes
    /// are produced, and the only writer of the record; `rebuildInspectorPane()` refines the
    /// inspector alone once `commandActions` exists, which is a redraw of the same key rather than
    /// a different one.
    ///
    /// Reaching a pane that is not on screen is safe and deliberate: a `rootView` write on an
    /// unparented hosting controller is deferred rather than lost, and the last value written is
    /// what mounts when the pane is put back. Do not force it with `layoutSubtreeIfNeeded()`, which
    /// `teardown()` needs only because its panes are never parented again: here it would mount every
    /// intermediate value instead of letting one run-loop turn settle on the final one.
    private func refreshPanes(of workspace: ConnectionWorkspace) {
        workspace.panes.sidebar.rootView = AnyView(buildSidebarView(for: workspace))
        workspace.panes.detail.rootView = AnyView(buildDetailView(for: workspace))
        workspace.panes.inspector.rootView = AnyView(buildInspectorView(for: workspace))
        refreshTabStripPane(of: workspace)
        workspace.panes.markRendered(workspace.paneRenderKey)
        guard isShowing(workspace) else { return }
        bindSidebarChrome(to: workspace)
    }

    /// The single entry point for a repaint, so a caller never has to know whether one is due. The
    /// record is what makes it free when nothing has moved, which is what lets a workspace switch
    /// ask for one without paying for the rebuild the panes exist to avoid.
    private func syncPanes(of workspace: ConnectionWorkspace) {
        guard workspace.paneRenderKey != workspace.panes.renderedKey else { return }
        refreshPanes(of: workspace)
    }

    private func syncSelectedPanes() {
        guard let selected = workspaces.selected else { return }
        syncPanes(of: selected)
    }

    /// Puts the selected connection's already-built panes on screen. This is the whole cost of a
    /// workspace switch now: three view swaps, with nothing rebuilt and nothing thrown away.
    private func showSelectedPanes() {
        let selected = workspaces.selected
        navigationSidebar.objectBrowser.show(selected?.panes.sidebar)
        detailPaneHost.show(selected?.panes.detail)
        inspectorPaneHost.show(selected?.panes.inspector)
        showSelectedTabStrip()
        if let selected { bindSidebarChrome(to: selected) }
    }

    /// The filter field lives above the object list and belongs to the window, so it follows the
    /// connection on screen rather than being owned by one.
    private func bindSidebarChrome(to workspace: ConnectionWorkspace) {
        guard let connection = workspace.connection, workspace.sessionState != nil else {
            navigationSidebar.objectBrowser.updateSidebarState(nil)
            return
        }
        navigationSidebar.objectBrowser.updateSidebarState(SharedSidebarState.forConnection(connection.id))
    }

    /// The command surface every menu action forwards into. Menu items reach this
    /// window because AppKit resolved them against its responder chain, so no
    /// key-window lookup or focus registry is involved.
    var commandActions: MainContentCommandActions? {
        sessionState?.coordinator.commandActions
    }

    var currentPane: ConnectionWindowPane {
        workspaces.selected?.resolvedPane ?? .unavailable(.notConnected)
    }

    /// The one answer to "does this window have a database to talk to". `releaseSession` keeps the
    /// coordinator alive across a reconnect on purpose, so the object graph outliving a session
    /// says nothing about the connection; only the phase separates dialing from connected from
    /// failed. The pane is part of the answer because a phase with nothing renderable behind it
    /// shows no content view for a command to act on.
    static func isConnected(phase: ConnectionWindowPhase, pane: ConnectionWindowPane) -> Bool {
        guard phase == .connected else { return false }
        return pane == .content
    }

    var isConnected: Bool {
        Self.isConnected(phase: phase, pane: currentPane)
    }

    private var paneConnection: DatabaseConnection? {
        workspaces.selected?.connection
    }

    /// Every builder takes the workspace it is building for. None of them may read `selected`: a
    /// workspace's panes are rebuilt whenever its own state changes, including while another
    /// connection is the one on screen, and reading the selection there would render the wrong
    /// connection's data into a background pane.
    ///
    /// None of them carries a SwiftUI `.id` either. Identity was how one shared hosting controller
    /// was told that its content had become a different connection; each workspace has its own now,
    /// so the tree is per-connection by construction and an identity would only throw it away.
    @ViewBuilder
    private func buildSidebarView(for workspace: ConnectionWorkspace) -> some View {
        if workspace.resolvedPane == .content,
           let session = workspace.session,
           let sessionState = workspace.sessionState {
            SidebarView(
                sidebarState: SharedSidebarState.forConnection(session.connection.id),
                windowState: sessionState.coordinator.windowSidebarState,
                pendingTruncates: sessionBinding(for: workspace, get: { $0.pendingTruncates }, set: { $0.pendingTruncates = $1 }, defaultValue: []),
                pendingDeletes: sessionBinding(for: workspace, get: { $0.pendingDeletes }, set: { $0.pendingDeletes = $1 }, defaultValue: []),
                tableOperationOptions: sessionBinding(for: workspace, get: { $0.tableOperationOptions }, set: { $0.tableOperationOptions = $1 }, defaultValue: [:]),
                databaseType: session.connection.type,
                connectionId: session.connection.id,
                coordinator: sessionState.coordinator
            )
            .transaction { $0.animation = nil }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func buildDetailView(for workspace: ConnectionWorkspace) -> some View {
        let pane = workspace.resolvedPane
        if pane == .connecting, let pendingConnection = workspace.connection {
            ConnectingStateView(connection: pendingConnection) { [weak self] in
                self?.cancelConnectionAttempt(for: workspace.connectionId)
            }
        } else if case .unavailable(let reason) = pane, let connection = workspace.connection {
            ConnectionUnavailableView(
                connection: connection,
                reason: reason,
                onPrimaryAction: { [weak self] in
                    self?.performUnavailablePrimaryAction(reason, for: workspace.connectionId)
                },
                onManageConnections: { [weak self] in self?.openConnectionList() }
            )
        } else if pane == .content,
                  let session = workspace.session,
                  let rightPanelState = workspace.rightPanelState,
                  let sessionState = workspace.sessionState {
            MainContentView(
                connection: session.connection,
                payload: workspace.payload,
                windowTitle: windowTitleBinding(for: workspace),
                windowSubtitle: windowSubtitleBinding(for: workspace),
                sidebarState: SharedSidebarState.forConnection(session.connection.id),
                pendingTruncates: sessionBinding(for: workspace, get: { $0.pendingTruncates }, set: { $0.pendingTruncates = $1 }, defaultValue: []),
                pendingDeletes: sessionBinding(for: workspace, get: { $0.pendingDeletes }, set: { $0.pendingDeletes = $1 }, defaultValue: []),
                tableOperationOptions: sessionBinding(for: workspace, get: { $0.tableOperationOptions }, set: { $0.tableOperationOptions = $1 }, defaultValue: [:]),
                rightPanelState: rightPanelState,
                tabManager: sessionState.tabManager,
                changeManager: sessionState.changeManager,
                toolbarState: sessionState.toolbarState,
                coordinator: sessionState.coordinator
            )
            .transaction { $0.animation = nil }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func buildInspectorView(for workspace: ConnectionWorkspace) -> some View {
        if let session = workspace.session, let rightPanelState = workspace.rightPanelState {
            UnifiedRightPanelView(
                state: rightPanelState,
                connection: session.connection
            )
            .environment(\.commandActions, workspace.sessionState?.coordinator.commandActions)
        } else {
            Color.clear
        }
    }

    /// Rebuilds the inspector alone. `commandActions` is read eagerly here, and it only exists
    /// once the detail pane has appeared, which is after `rebuildPanes()` has already built the
    /// inspector against a nil value. Rebuilding the detail pane too would remount the very view
    /// that publishes those actions.
    func rebuildInspectorPane() {
        guard let selected = workspaces.selected else { return }
        selected.panes.inspector.rootView = AnyView(buildInspectorView(for: selected))
    }

    // MARK: - Session Bindings

    /// Bound to one workspace's session, not to whichever one is on screen. The old binding read
    /// `currentSession` at access time, which was right only while a dead background tree could not
    /// read anything: now that every connection keeps its tree, that binding would have handed a
    /// background pane the selected connection's pending truncates and written its edits back onto
    /// the wrong session.
    private func sessionBinding<T>(
        for workspace: ConnectionWorkspace,
        get: @escaping (ConnectionSession) -> T,
        set: @escaping (inout ConnectionSession, T) -> Void,
        defaultValue: T
    ) -> Binding<T> {
        let connectionId = workspace.connectionId
        return Binding(
            get: { [weak workspace] in
                guard let session = workspace?.session else { return defaultValue }
                return get(session)
            },
            set: { newValue in
                Task {
                    DatabaseManager.shared.updateSession(connectionId) { session in
                        set(&session, newValue)
                    }
                }
            }
        )
    }

    /// The window has one titlebar, so only the connection on screen may name it. Every hosted
    /// connection's `MainContentView` writes here whenever its selected tab changes, and those
    /// writes no longer stop when the user switches away, because the view is still mounted.
    private func windowTitleBinding(for workspace: ConnectionWorkspace) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.windowTitle ?? "" },
            set: { [weak self] newValue in
                guard let self, self.isShowing(workspace) else { return }
                self.windowTitle = newValue
            }
        )
    }

    private func windowSubtitleBinding(for workspace: ConnectionWorkspace) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.windowSubtitle ?? "" },
            set: { [weak self] newValue in
                guard let self, self.isShowing(workspace) else { return }
                self.windowSubtitle = newValue
            }
        )
    }

    private func isShowing(_ workspace: ConnectionWorkspace) -> Bool {
        workspaces.selectedConnectionId == workspace.connectionId
    }

    // MARK: - InspectorVisibilityProxy

    var isInspectorVisible: Bool {
        guard let inspectorSplitItem else { return false }
        return !inspectorSplitItem.isCollapsed
    }

    func showInspector() {
        rebuildInspectorPane()
        inspectorSplitItem?.animator().isCollapsed = false
        recomputeWindowMinSize()
    }

    func hideInspector() {
        inspectorSplitItem?.animator().isCollapsed = true
        recomputeWindowMinSize()
    }

    @objc override func toggleInspector(_ sender: Any?) {
        toggleInspector()
    }

    // MARK: - Workspace Rail

    /// The menu title has to describe what the command mutates, which is the setting. Reading
    /// the live pane state instead made the item read "Show Workspace Rail" forever whenever
    /// the auto-hide rule was the thing keeping the rail off screen.
    var isWorkspaceRailEnabled: Bool {
        AppSettingsManager.shared.general.showWorkspaceRail
    }

    var canToggleWorkspaceRail: Bool {
        WorkspaceRailStore.entries.count > 1
    }


    /// Driven off the persisted setting rather than this window's live pane state, so a
    /// window whose rail drifted out of sync cannot swallow the toggle.
    func toggleWorkspaceRail() {
        AppSettingsManager.shared.general.showWorkspaceRail.toggle()
    }

    /// How many workspaces the strip has to offer, which is an app-wide count: every window's
    /// strip lists every workspace, and picking one raises the window that hosts it. Held rather
    /// than re-read, so the pane changing can re-decide the strip without `applyPaneChrome`
    /// reaching for a global of its own.
    private var hostedWorkspaceCount = 0

    /// The strip's own visibility, and then everything standing on it. Called directly whenever
    /// the app-wide count moves, which happens without this window's phase moving at all: a
    /// sibling connection opening or closing is enough.
    func applyRailVisibility(workspaceCount: Int) {
        hostedWorkspaceCount = workspaceCount
        setWorkspaceRailVisible(
            ConnectionWindowPaneResolver.showsWorkspaceRail(
                preferenceEnabled: AppSettingsManager.shared.general.showWorkspaceRail,
                workspaceCount: workspaceCount,
                pane: currentPane,
                isClosing: phase == .closing
            )
        )
        applyChromeStandingOnRail()
    }

    /// The sidebar item's minimum is a required constraint, so it lands on the very next layout
    /// pass. Applying it outside the rail's own animation snapped the pane its full width wide in
    /// one frame while the rail slid in behind it, so the object browser lurched and settled back.
    private func setWorkspaceRailVisible(_ visible: Bool) {
        guard let navigationSidebar, navigationSidebar.isRailVisible != visible else { return }
        navigationSidebar.setRailVisible(visible, animated: view.window != nil) { [weak self] in
            self?.recomputeWindowMinSize()
        }
    }

    func activateWorkspace(offsetBy offset: Int) {
        navigationSidebar?.railController.activateWorkspace(offsetBy: offset)
    }

    // MARK: - Sidebar

    /// Whether the object browser is off screen, which is the question every caller is really
    /// asking: the toolbar's segment, the Show/Hide Sidebar title and the reveal actions. A sidebar
    /// narrowed to the workspace rail is an open split item with no object browser in it, so the
    /// item's own flag is not the answer on its own.
    var isSidebarCollapsed: Bool {
        guard sidebarChromeMode.showsObjectBrowser else { return true }
        return sidebarSplitItem?.isCollapsed ?? true
    }

    var isSidebarUserCollapsible: Bool {
        sidebarSplitItem?.canCollapse ?? false
    }

    var sidebarThicknessRange: (min: CGFloat, max: CGFloat) {
        (sidebarSplitItem?.minimumThickness ?? 0, sidebarSplitItem?.maximumThickness ?? 0)
    }

    var railAllowance: CGFloat {
        navigationSidebar?.railAllowance ?? 0
    }

    /// Every collapse route reaches AppKit's own `toggleSidebar(_:)`: the View menu sends the
    /// selector down the responder chain, and so does the toolbar's sidebar button. Overriding
    /// it is the one place that catches them all, so the toolbar's segment can never stay lit
    /// over a collapsed sidebar.
    override func toggleSidebar(_ sender: Any?) {
        super.toggleSidebar(sender)
        toolbarOwner?.syncSidebarSelection()
    }

    func focusSidebarSearch() {
        guard sidebarChromeMode.showsObjectBrowser else { return }
        if sidebarSplitItem?.isCollapsed == true {
            sidebarSplitItem?.animator().isCollapsed = false
        }
        navigationSidebar.objectBrowser.focusSearchField()
    }

    func presentDatabaseFilter() {
        guard sidebarChromeMode.showsObjectBrowser else { return }
        guard let connectionId = currentSession?.connection.id else { return }
        if sidebarSplitItem?.isCollapsed == true {
            sidebarSplitItem?.isCollapsed = false
        }
        navigationSidebar.objectBrowser.presentDatabaseFilter(
            connectionId: connectionId,
            sidebarState: SharedSidebarState.forConnection(connectionId)
        )
    }

    func clearDatabaseFilter() {
        guard let connectionId = currentSession?.connection.id else { return }
        let state = SharedSidebarState.forConnection(connectionId)
        guard !state.databaseFilterSelected.isEmpty else { return }
        state.databaseFilterSelected = []
    }

    /// Refused while the sidebar is narrowed to the workspace rail. The item is open, so the
    /// collapse branch below would read it as showing and collapse it, taking the rail and every
    /// route to the window's other connections with it.
    func setSidebarTab(_ tab: SidebarTab) {
        guard sidebarChromeMode.showsObjectBrowser else { return }
        guard let connectionId = currentSession?.connection.id else { return }
        let sidebarState = SharedSidebarState.forConnection(connectionId)

        if sidebarSplitItem?.isCollapsed == true {
            sidebarState.selectedSidebarTab = tab
            sidebarSplitItem?.animator().isCollapsed = false
        } else if sidebarState.selectedSidebarTab == tab {
            sidebarSplitItem?.animator().isCollapsed = true
        } else {
            sidebarState.selectedSidebarTab = tab
        }
        toolbarOwner?.syncSidebarSelection()
    }

    // MARK: - Dynamic Window Minimum Size

    static let baseWindowMinWidth: CGFloat = 720
    static let baseWindowMinHeight: CGFloat = 480
    static let sidebarMinThickness: CGFloat = 280
    static let defaultDetailMinThickness: CGFloat = 400
    static let inspectorMinThickness: CGFloat = 270
    private static let sidebarMaxThickness: CGFloat = 600

    static func resolveDetailMinimumThickness(for tabType: TabType?) -> CGFloat {
        guard let tabType else { return defaultDetailMinThickness }
        switch tabType {
        case .usersRoles:
            return UsersRolesLayoutMetrics.tabMinimumWidth
        case .query, .table, .createTable, .erDiagram, .serverDashboard, .insights, .objectSource:
            return defaultDetailMinThickness
        }
    }

    /// The rail lives inside the sidebar item, so its width is part of that item's minimum
    /// rather than a separate window-level allowance. A split item's minimum is what a
    /// divider drag actually stops at, so charging the rail only to the window let a drag
    /// squeeze the object browser below the width it is designed for.
    static func resolveSidebarMinimumThickness(railAllowance: CGFloat) -> CGFloat {
        sidebarMinThickness + railAllowance
    }

    static func resolveWindowMinWidth(
        detailMinimum: CGFloat,
        sidebarVisible: Bool,
        inspectorVisible: Bool,
        sidebarMinimum: CGFloat,
        dividerThickness: CGFloat
    ) -> CGFloat {
        var width = detailMinimum
        if sidebarVisible {
            width += sidebarMinimum + dividerThickness
        }
        if inspectorVisible {
            width += inspectorMinThickness + dividerThickness
        }
        return max(baseWindowMinWidth, width)
    }

    /// The window has one detail split item, so its minimum belongs to the connection on screen.
    /// Every hosted connection's `MainContentView` calls this whenever its selected tab changes, and
    /// those calls no longer stop when the user switches away, so a background connection sitting on
    /// a wide tab would raise the visible connection's minimum and the window's own minimum with it.
    func updateDetailMinimumThickness(for tabType: TabType?, connectionId: UUID) {
        guard workspaces.selectedConnectionId == connectionId else { return }
        let resolved = Self.resolveDetailMinimumThickness(for: tabType)
        guard let detailSplitItem, detailSplitItem.minimumThickness != resolved else { return }
        detailSplitItem.minimumThickness = resolved
        recomputeWindowMinSize()
    }

    /// Re-seeded on every switch, because the item is shared and the value it holds describes
    /// whichever connection was last on screen.
    private func applyDetailMinimumThicknessForSelection() {
        guard let selected = workspaces.selected else { return }
        updateDetailMinimumThickness(
            for: selected.sessionState?.tabManager.selectedTab?.tabType,
            connectionId: selected.connectionId
        )
    }

    /// Inert while the sidebar is clamped to the rail. Seven other call sites reach
    /// `recomputeWindowMinSize`, and any of them writing the object browser's minimum back over the
    /// clamp would leave a minimum above the maximum.
    private func applySidebarMinimumThickness() {
        guard let sidebarSplitItem else { return }
        guard appliedSidebarMode ?? .revealed == .revealed else { return }
        let resolved = Self.resolveSidebarMinimumThickness(
            railAllowance: navigationSidebar?.railAllowance ?? 0
        )
        guard sidebarSplitItem.minimumThickness != resolved else { return }
        sidebarSplitItem.minimumThickness = resolved
    }

    private func recomputeWindowMinSize() {
        applySidebarMinimumThickness()
        guard let window = view.window else { return }
        let sidebarVisible = !(sidebarSplitItem?.isCollapsed ?? true)
        let inspectorVisible = !(inspectorSplitItem?.isCollapsed ?? true)

        let resolvedWidth = Self.resolveWindowMinWidth(
            detailMinimum: detailSplitItem?.minimumThickness ?? Self.defaultDetailMinThickness,
            sidebarVisible: sidebarVisible,
            inspectorVisible: inspectorVisible,
            sidebarMinimum: sidebarSplitItem?.minimumThickness ?? Self.sidebarMinThickness,
            dividerThickness: splitView.dividerThickness
        )
        let newMinSize = NSSize(width: resolvedWidth, height: Self.baseWindowMinHeight)

        guard window.minSize != newMinSize else { return }
        window.minSize = newMinSize

        var frame = window.frame
        var resized = false
        if frame.size.width < resolvedWidth {
            frame.size.width = resolvedWidth
            resized = true
        }
        if frame.size.height < Self.baseWindowMinHeight {
            frame.size.height = Self.baseWindowMinHeight
            resized = true
        }
        if resized {
            window.setFrame(frame, display: true, animate: false)
        }
    }

    // MARK: - Panel Layout Persistence

    // MARK: - Pane Chrome

    private var userPaneLayout: ChromePaneLayout?

    /// What this window's sidebar is currently showing, and `nil` before the first application.
    /// The resolver decides the mode; this records which one has been put on screen.
    private var appliedSidebarMode: SidebarChromeMode?

    internal var sidebarChromeMode: SidebarChromeMode {
        ConnectionWindowPaneResolver.sidebarChromeMode(
            for: currentPane,
            hasRail: navigationSidebar?.isRailVisible ?? false
        )
    }

    /// A split item's collapse state is written into the autosave record, which is how the
    /// inspector remembers being hidden. Collapsing the sidebar for a phase the user did not
    /// choose would persist that as their layout and lose the width they set, so autosaving is
    /// switched off for the whole span the chrome is not revealed and switched back on to restore
    /// it. The same is true of a clamp, which writes its narrow width into the record the way a
    /// collapse writes the collapsed flag.
    ///
    /// The strip is settled first, because everything after it reads whether one is on screen: the
    /// sidebar clamps to a width the strip's own constraints report, and that width is zero until
    /// the strip is laid out. Running the pane through it is also what brings a hidden strip back
    /// when a connection goes down, which is the window's last route to the ones it still hosts.
    func applyPaneChrome() {
        applyRailVisibility(workspaceCount: hostedWorkspaceCount)
    }

    private func applyChromeStandingOnRail() {
        applySidebarChromeMode(sidebarChromeMode)
        applyTabStripVisibility()
        toolbarOwner?.managedToolbar.validateVisibleItems()
        recomputeWindowMinSize()
    }

    private func applySidebarChromeMode(_ mode: SidebarChromeMode) {
        guard appliedSidebarMode != mode else { return }
        let previous = appliedSidebarMode
        appliedSidebarMode = mode

        guard mode != .revealed else {
            revealWindowChrome()
            return
        }

        /// Captured on the way out of `revealed` and never again, because the geometry a
        /// `railOnly` to `hidden` step would see is the clamp, not the width the user chose.
        if previous == nil || previous == .revealed {
            resignFirstResponderInsideChrome()
            splitView.autosaveName = nil
            userPaneLayout = ChromePaneLayout(
                isSidebarCollapsed: sidebarSplitItem.isCollapsed,
                isInspectorCollapsed: inspectorSplitItem.isCollapsed
            )
        }

        inspectorSplitItem.isCollapsed = true
        switch mode {
        case .railOnly:
            sidebarSplitItem.isCollapsed = false
            clampSidebarToRail()
        case .hidden:
            releaseSidebarClamp()
            sidebarSplitItem.isCollapsed = true
        case .revealed:
            break
        }
        view.window?.recalculateKeyViewLoop()
    }

    /// Narrowed rather than collapsed, so the rail stays on screen while the object browser it
    /// shares a split item with goes. Measured: clamping and later releasing returns the item to
    /// the width the user set, but a `setPosition` while the clamp holds discards it, which is why
    /// nothing else may write the sidebar's thickness for the span.
    private func clampSidebarToRail() {
        let allowance = navigationSidebar?.railAllowance ?? 0
        sidebarSplitItem.minimumThickness = allowance
        sidebarSplitItem.maximumThickness = allowance
        /// A clamp is not a lock. AppKit still collapses a collapsible item on a divider
        /// double-click or a drag to the edge, which no menu or toolbar validation sees, and the
        /// mode is already applied so nothing would open it again.
        sidebarSplitItem.canCollapse = false
    }

    internal func reapplySidebarClampIfNarrowed() {
        guard appliedSidebarMode == .railOnly else { return }
        clampSidebarToRail()
    }

    private func releaseSidebarClamp() {
        sidebarSplitItem.canCollapse = true
        sidebarSplitItem.maximumThickness = Self.sidebarMaxThickness
        applySidebarMinimumThickness()
    }

    /// Autosaving is off while the chrome is not revealed, so the record still holds what the user
    /// had. AppKit will not re-apply it though: assigning an autosave name to a split view that has
    /// already laid out restores nothing. The state captured on the way in is therefore what gives
    /// the panes back. Forcing the sidebar open here instead reopened a sidebar the user had
    /// deliberately hidden, every time a connection dropped and came back.
    private func revealWindowChrome() {
        releaseSidebarClamp()

        /// Only a reveal that follows a hide has something to put back. A first reveal is a window
        /// opening on a live connection, where the panes are already where the user's autosaved
        /// layout put them, and writing over them would discard that.
        if let restored = userPaneLayout {
            userPaneLayout = nil
            sidebarSplitItem.isCollapsed = restored.isSidebarCollapsed
            inspectorSplitItem.isCollapsed = restored.isInspectorCollapsed
        }
        restoreUserPaneLayout()
        view.window?.recalculateKeyViewLoop()
    }

    private func restoreUserPaneLayout() {
        splitView.autosaveName = splitAutosaveName
    }

    /// A collapsed pane keeps whatever first responder it held, which would leave the window
    /// typing into a search field nobody can see.
    private func resignFirstResponderInsideChrome() {
        guard let window = view.window,
              let responder = window.firstResponder as? NSView else { return }
        guard responder.isDescendant(of: navigationSidebar.view)
            || responder.isDescendant(of: inspectorPaneHost.view) else { return }
        window.makeFirstResponder(nil)
    }

    /// Show/Hide Sidebar and Inspector stay in the responder chain while collapsed, so without
    /// this the user can reopen an empty pane over a window that has no session yet.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)) || item.action == #selector(toggleInspector(_:)) {
            return currentPane == .content
        }
        return super.validateUserInterfaceItem(item)
    }
}

// MARK: - Inspector Environment

/// The inspector is its own `NSHostingController`, so `@FocusedValue` set in the detail pane
/// never reaches it. This window's controller injects its own actions instead.
private struct CommandActionsEnvironmentKey: EnvironmentKey {
    static let defaultValue: MainContentCommandActions? = nil
}

extension EnvironmentValues {
    var commandActions: MainContentCommandActions? {
        get { self[CommandActionsEnvironmentKey.self] }
        set { self[CommandActionsEnvironmentKey.self] = newValue }
    }
}
