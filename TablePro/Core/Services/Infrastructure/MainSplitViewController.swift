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
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

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
            guard let selected = workspaces.selected, selected.phase != newValue else { return }
            selected.phase = newValue
            applyPhase()
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
    private var detailHosting: NSHostingController<AnyView>!
    private var tabStripHosting: NSHostingController<AnyView>?
    private var tabStripAccessory: NSTitlebarAccessoryViewController?
    private var inspectorHosting: NSHostingController<AnyView>!

    private var chromeState: ChromeState = .unapplied

    // MARK: - Panel Layout State

    /// Never version this key to force a relayout. `NSSplitView` clamps a restored frame against
    /// the current minimums, so the sidebar simply widens to fit the rail. Bumping it instead
    /// throws away every saved sidebar width, inspector width and collapse state the user has,
    /// leaves the old keys orphaned in `UserDefaults`, and reads as a regression nobody asked for.
    private var splitAutosaveName: NSSplitView.AutosaveName {
        if let connectionId = payload?.connectionId ?? currentSession?.connection.id {
            return "com.TablePro.mainSplit.\(connectionId.uuidString)"
        }
        return "com.TablePro.mainSplit"
    }

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

    init(payload: EditorTabPayload?, sessionState: SessionStateFactory.SessionState?, autoConnect: Bool = false) {
        self.windowTitle = ""
        self.windowSubtitle = ""

        super.init(nibName: nil, bundle: nil)

        adoptWorkspace(payload: payload, autoConnect: autoConnect)

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

        let phase: ConnectionWindowPhase
        if resolvedSession?.driver != nil {
            phase = .connected
        } else if resolvedSession != nil {
            phase = .connecting
        } else {
            phase = .idle
        }

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
        return workspaces.insert(workspace)
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

        navigationSidebar = NavigationSidebarViewController(
            connectionId: payload?.connectionId ?? currentSession?.connection.id
        )
        navigationSidebar.railController.onLayoutChange = { [weak self] _ in
            self?.navigationSidebar.applyRailWidth(animated: false)
            self?.recomputeWindowMinSize()
        }
        sidebarSplitItem = NSSplitViewItem(sidebarWithViewController: navigationSidebar)
        sidebarSplitItem.canCollapse = true
        sidebarSplitItem.minimumThickness = Self.sidebarMinThickness
        sidebarSplitItem.maximumThickness = Self.sidebarMaxThickness
        addSplitViewItem(sidebarSplitItem)

        detailHosting = NSHostingController(rootView: AnyView(Color.clear))
        detailHosting.sizingOptions = []
        detailSplitItem = NSSplitViewItem(viewController: detailHosting)
        detailSplitItem.minimumThickness = Self.resolveDetailMinimumThickness(for: payload?.tabType)
        detailSplitItem.holdingPriority = .defaultLow
        addSplitViewItem(detailSplitItem)

        inspectorHosting = NSHostingController(rootView: AnyView(Color.clear))
        inspectorHosting.sizingOptions = []
        inspectorSplitItem = NSSplitViewItem(inspectorWithViewController: inspectorHosting)
        inspectorSplitItem.canCollapse = true
        inspectorSplitItem.minimumThickness = Self.inspectorMinThickness
        inspectorSplitItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
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

        restoreUserPaneLayout()
        rebuildPanes()
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
    private func handleConnectionRecordChange(_ changedId: UUID?) {
        let stored = ConnectionStorage.shared.loadConnections()
        var repaint = false
        for workspace in workspaces.workspaces {
            let connectionId = workspace.connectionId
            guard changedId == nil || changedId == connectionId else { continue }
            guard let record = stored.first(where: { $0.id == connectionId })
                ?? DatabaseManager.shared.activeSessions[connectionId]?.connection else { continue }
            workspace.payloadConnection = record
            if workspaces.selectedConnectionId == connectionId { repaint = true }
        }
        guard repaint else { return }
        applyWindowTitle()
        rebuildPanes()
    }

    // MARK: - Toolbar

    /// Only ever called with a live coordinator. The toolbar's delegate builds no item without
    /// one, and `NSToolbar` asks it once, so a toolbar created early is permanently empty: a
    /// later coordinator cannot refill it, and validation only speaks to items that already
    /// exist. A window with no session shows a plain titlebar instead.
    /// `NSToolbar` asks its delegate for an item once and keeps what it returns, and every item
    /// view captures the coordinator it was built with. Reassigning the owner's coordinator
    /// therefore repoints nothing: the toolbar goes on naming, and acting on, the connection it
    /// was built for. Switching connection rebuilds it instead.
    func installToolbar(coordinator: MainContentCoordinator) {
        guard let window = view.window else { return }
        if let owner = toolbarOwner, owner.coordinator !== coordinator {
            invalidateToolbar()
        }
        if toolbarOwner == nil {
            toolbarOwner = MainWindowToolbar(coordinator: coordinator)
        }
        if let owner = toolbarOwner, window.toolbar !== owner.managedToolbar {
            window.toolbar = owner.managedToolbar
        }
    }

    func invalidateToolbar() {
        toolbarOwner?.invalidate()
        toolbarOwner = nil
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
            wasDisconnectedByUser: DatabaseManager.shared.wasDisconnectedByUser(sid)
        )
        let nextPhase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: workspace.phase,
            session: snapshot,
            ownsAttempt: workspace.attemptToken != nil
        )
        let isSelected = workspaces.selectedConnectionId == sid

        if nextPhase == .connected, let session {
            let alreadyRendered = workspace.session?.isContentViewEquivalent(to: session) ?? false
            if alreadyRendered, workspace.phase == nextPhase { return }
            adoptSession(session, into: workspace)
            if workspace.phase == nextPhase, isSelected { rebuildPanes() }
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
        workspace.sessionState?.coordinator.teardown()
        workspace.sessionState = nil
        workspace.session = nil
        if workspaces.selectedConnectionId == workspace.connectionId {
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

        if let coordinator = workspaces.selected?.sessionState?.coordinator {
            coordinator.inspectorProxy = self
            coordinator.splitViewController = self
            installToolbar(coordinator: coordinator)
        }
        rebuildPanes()
        applyPaneChrome()
        applyWindowTitle()

        /// The rail redraws from `WorkspaceRailStore.changes`, which listens to session and tab
        /// events. Switching workspace in place fires none of them, so without this the rail kept
        /// highlighting the connection the user just switched away from.
        AppEvents.shared.connectionWindowsChanged.send()
    }

    private func applyPhase() {
        rebuildPanes()
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

    /// A window now hosts several connections, so a phase change has to name the one it belongs
    /// to. Repainting is skipped for a workspace the user is not looking at: its state is still
    /// correct, it simply is not the thing on screen.
    internal func transition(to next: ConnectionWindowPhase, for connectionId: UUID) {
        guard let workspace = workspaces.workspace(for: connectionId) else { return }
        guard workspace.phase != next else { return }
        workspace.phase = next
        if workspaces.selectedConnectionId == connectionId {
            applyPhase()
        } else {
            SessionRecoveryTracker.sync()
        }
    }

    internal func refreshFromActiveSessions() {
        handleConnectionStatusChange()
    }

    /// Closing the window closes every connection it hosts, so each workspace has to reach
    /// `.closing` on its own. Leaving a background one behind would let it keep a restore
    /// intent for a window that no longer exists.
    internal func markWindowClosing() {
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

    private func rebuildPanes() {
        navigationSidebar.objectBrowser.rootView = AnyView(buildSidebarView())
        if let currentSession, sessionState != nil {
            navigationSidebar.objectBrowser.updateSidebarState(
                SharedSidebarState.forConnection(currentSession.connection.id)
            )
        }
        detailHosting.rootView = AnyView(buildDetailView())
        inspectorHosting.rootView = AnyView(buildInspectorView())
        refreshTabStripAccessory()
    }

    /// The tab strip belongs in the titlebar, where every document app puts its tabs, not stacked
    /// inside the content area. The accessory is per-window while the strip is per-workspace, so
    /// switching workspace has to repoint it rather than build a second one.
    private func installTabStripAccessoryIfNeeded() {
        guard tabStripAccessory == nil, let window = view.window else { return }
        let hosting = NSHostingController<AnyView>(rootView: AnyView(Color.clear))
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(
            x: 0,
            y: 0,
            width: window.frame.width,
            height: EditorTabStripLayout.totalHeight
        )

        let accessory = NSTitlebarAccessoryViewController()
        accessory.addChild(hosting)
        accessory.view = hosting.view
        accessory.layoutAttribute = .bottom
        /// Defaults to true, and means "use the standard system sizing over the view's frame",
        /// which is the opposite of what a fixed-height strip wants.
        accessory.automaticallyAdjustsSize = false
        accessory.fullScreenMinHeight = 0
        accessory.isHidden = true
        window.addTitlebarAccessoryViewController(accessory)

        tabStripHosting = hosting
        tabStripAccessory = accessory
        refreshTabStripAccessory()
    }

    private func refreshTabStripAccessory() {
        installTabStripAccessoryIfNeeded()
        guard let accessory = tabStripAccessory, let hosting = tabStripHosting else { return }
        defer { observeTabStripSource() }
        guard currentPane == .content, let sessionState, sessionState.tabManager.tabs.count > 1 else {
            accessory.isHidden = true
            hosting.rootView = AnyView(Color.clear)
            recomputeWindowMinSize()
            return
        }
        hosting.rootView = AnyView(buildTabStripView(sessionState: sessionState))
        accessory.isHidden = false
        recomputeWindowMinSize()
    }

    /// The strip lived in SwiftUI before, where the tab count was observed for free. An AppKit
    /// accessory observes nothing, so opening a second tab left it hidden: `rebuildPanes` is the
    /// only caller of the refresh and a tab list change never reaches it. `withObservationTracking`
    /// fires once, so each pass re-arms the next.
    private func observeTabStripSource() {
        guard let manager = workspaces.selected?.sessionState?.tabManager else { return }
        withObservationTracking {
            _ = manager.tabs.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshTabStripAccessory()
            }
        }
    }

    private func buildTabStripView(sessionState: SessionStateFactory.SessionState) -> some View {
        EditorTabStrip(
            tabManager: sessionState.tabManager,
            onClose: { [weak self] id in self?.commandActions?.closeTab(id: id) },
            onCloseOthers: { [weak self] id in self?.commandActions?.closeOtherTabs(anchoredOn: id) },
            onCloseAll: { [weak self] in self?.commandActions?.closeAllTabs() },
            onNewTab: { [weak self] in self?.commandActions?.newTab() }
        )
    }

    /// The command surface every menu action forwards into. Menu items reach this
    /// window because AppKit resolved them against its responder chain, so no
    /// key-window lookup or focus registry is involved.
    var commandActions: MainContentCommandActions? {
        sessionState?.coordinator.commandActions
    }

    var currentPane: ConnectionWindowPane {
        ConnectionWindowPaneResolver.pane(
            phase: phase,
            hasConnection: paneConnection != nil,
            hasRenderableSession: currentSession != nil && rightPanelState != nil && sessionState != nil
        )
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
        payloadConnection ?? currentSession?.connection
    }

    @ViewBuilder
    private func buildSidebarView() -> some View {
        if currentPane == .content, let currentSession, let sessionState {
            sidebarBody(currentSession: currentSession, sessionState: sessionState)
                .transaction { $0.animation = nil }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func sidebarBody(
        currentSession: ConnectionSession,
        sessionState: SessionStateFactory.SessionState
    ) -> some View {
        SidebarView(
            sidebarState: SharedSidebarState.forConnection(currentSession.connection.id),
            windowState: sessionState.coordinator.windowSidebarState,
            onDoubleClick: { [weak self] table in
                guard let coordinator = self?.sessionState?.coordinator else { return }
                let activeTab = coordinator.tabManager.selectedTab
                if activeTab?.tabType == .table, activeTab?.tableContext.tableName == table.name {
                    coordinator.promotePreviewTab()
                    coordinator.requestGridFocus()
                } else {
                    coordinator.openTableTab(table, forceNonPreview: true, activateGridFocus: true)
                }
            },
            pendingTruncates: sessionPendingTruncatesBinding,
            pendingDeletes: sessionPendingDeletesBinding,
            tableOperationOptions: sessionTableOperationOptionsBinding,
            databaseType: currentSession.connection.type,
            connectionId: currentSession.connection.id,
            coordinator: sessionState.coordinator
        )
    }

    @ViewBuilder
    private func buildDetailView() -> some View {
        if currentPane == .connecting, let pendingConnection = paneConnection {
            ConnectingStateView(connection: pendingConnection) { [weak self] in
                self?.cancelConnectionAttempt()
            }
        } else if case .unavailable(let reason) = currentPane, let connection = paneConnection {
            ConnectionUnavailableView(
                connection: connection,
                reason: reason,
                onPrimaryAction: { [weak self] in self?.performUnavailablePrimaryAction(reason) },
                onManageConnections: { [weak self] in self?.openConnectionList() }
            )
        } else if currentPane == .content, let currentSession, let rightPanelState, let sessionState {
            MainContentView(
                connection: currentSession.connection,
                payload: payload,
                windowTitle: windowTitleBinding,
                windowSubtitle: windowSubtitleBinding,
                sidebarState: SharedSidebarState.forConnection(currentSession.connection.id),
                pendingTruncates: sessionPendingTruncatesBinding,
                pendingDeletes: sessionPendingDeletesBinding,
                tableOperationOptions: sessionTableOperationOptionsBinding,
                rightPanelState: rightPanelState,
                tabManager: sessionState.tabManager,
                changeManager: sessionState.changeManager,
                toolbarState: sessionState.toolbarState,
                coordinator: sessionState.coordinator
            )
            /// The detail pane is a different view per connection, not one view whose inputs
            /// changed. Without an identity its `@State` (whether tabs have been restored, the
            /// cached change manager, the window id) survives a workspace switch, so the second
            /// connection either never restores or overwrites its live tabs with a disk snapshot.
            .id(currentSession.connection.id)
            .transaction { $0.animation = nil }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func buildInspectorView() -> some View {
        if let currentSession, let rightPanelState {
            UnifiedRightPanelView(
                state: rightPanelState,
                connection: currentSession.connection
            )
            .environment(\.commandActions, commandActions)
        } else {
            Color.clear
        }
    }

    /// Rebuilds the inspector alone. `commandActions` is read eagerly here, and it only exists
    /// once the detail pane has appeared, which is after `rebuildPanes()` has already built the
    /// inspector against a nil value. Rebuilding the detail pane too would remount the very view
    /// that publishes those actions.
    func rebuildInspectorPane() {
        guard let inspectorHosting else { return }
        inspectorHosting.rootView = AnyView(buildInspectorView())
    }

    // MARK: - Session Bindings

    private func createSessionBinding<T>(
        get: @escaping (ConnectionSession) -> T,
        set: @escaping (inout ConnectionSession, T) -> Void,
        defaultValue: T
    ) -> Binding<T> {
        Binding(
            get: { [weak self] in
                guard let session = self?.currentSession else { return defaultValue }
                return get(session)
            },
            set: { [weak self] newValue in
                guard let sessionId = self?.payload?.connectionId ?? self?.currentSession?.id else { return }
                Task {
                    DatabaseManager.shared.updateSession(sessionId) { session in
                        set(&session, newValue)
                    }
                }
            }
        )
    }

    private var sessionPendingTruncatesBinding: Binding<Set<String>> {
        createSessionBinding(get: { $0.pendingTruncates }, set: { $0.pendingTruncates = $1 }, defaultValue: [])
    }

    private var sessionPendingDeletesBinding: Binding<Set<String>> {
        createSessionBinding(get: { $0.pendingDeletes }, set: { $0.pendingDeletes = $1 }, defaultValue: [])
    }

    private var sessionTableOperationOptionsBinding: Binding<[String: TableOperationOptions]> {
        createSessionBinding(get: { $0.tableOperationOptions }, set: { $0.tableOperationOptions = $1 }, defaultValue: [:])
    }

    private var windowTitleBinding: Binding<String> {
        Binding(
            get: { [weak self] in self?.windowTitle ?? "" },
            set: { [weak self] in self?.windowTitle = $0 }
        )
    }

    private var windowSubtitleBinding: Binding<String> {
        Binding(
            get: { [weak self] in self?.windowSubtitle ?? "" },
            set: { [weak self] in self?.windowSubtitle = $0 }
        )
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

    /// A rail listing one workspace is a switcher with nothing to switch to, so it earns
    /// its width only once a second connection or database is open.
    static func shouldShowWorkspaceRail(settingEnabled: Bool, workspaceCount: Int) -> Bool {
        settingEnabled && workspaceCount > 1
    }

    func applyRailVisibility(workspaceCount: Int) {
        setWorkspaceRailVisible(
            Self.shouldShowWorkspaceRail(
                settingEnabled: AppSettingsManager.shared.general.showWorkspaceRail,
                workspaceCount: workspaceCount
            )
        )
    }

    /// The sidebar item's minimum is a required constraint, so it lands on the very next layout
    /// pass. Applying it outside the rail's own animation snapped the pane its full width wide in
    /// one frame while the rail slid in behind it, so the object browser lurched and settled back.
    func setWorkspaceRailVisible(_ visible: Bool) {
        guard let navigationSidebar, navigationSidebar.isRailVisible != visible else { return }
        navigationSidebar.setRailVisible(visible, animated: view.window != nil) { [weak self] in
            self?.recomputeWindowMinSize()
        }
    }

    func activateWorkspace(offsetBy offset: Int) {
        navigationSidebar?.railController.activateWorkspace(offsetBy: offset)
    }

    // MARK: - Sidebar

    var isSidebarCollapsed: Bool {
        sidebarSplitItem?.isCollapsed ?? true
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
        if sidebarSplitItem?.isCollapsed == true {
            sidebarSplitItem?.animator().isCollapsed = false
        }
        navigationSidebar.objectBrowser.focusSearchField()
    }

    func setSidebarTab(_ tab: SidebarTab) {
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
        case .query, .table, .createTable, .erDiagram, .serverDashboard:
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

    func updateDetailMinimumThickness(for tabType: TabType?) {
        let resolved = Self.resolveDetailMinimumThickness(for: tabType)
        guard let detailSplitItem, detailSplitItem.minimumThickness != resolved else { return }
        detailSplitItem.minimumThickness = resolved
        recomputeWindowMinSize()
    }

    private func applySidebarMinimumThickness() {
        guard let sidebarSplitItem else { return }
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
        let accessoryHeight = (tabStripAccessory?.isHidden ?? true) ? 0 : EditorTabStripLayout.totalHeight
        let newMinSize = NSSize(
            width: resolvedWidth,
            height: Self.baseWindowMinHeight + accessoryHeight
        )

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

    private func applyDefaultCollapseStateIfNoAutosave() {
        let key = "NSSplitView Subview Frames \(splitAutosaveName)"
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        inspectorSplitItem.isCollapsed = true
    }

    // MARK: - Pane Chrome

    private enum ChromeState {
        case unapplied
        case hidden
        case revealed
    }

    /// A split item's collapse state is written into the autosave record, which is how the
    /// inspector remembers being hidden. Collapsing the sidebar for a phase the user did not
    /// choose would persist that as their layout and lose the width they set, so autosaving is
    /// switched off for the whole span the chrome is hidden and switched back on to restore it.
    func applyPaneChrome() {
        if ConnectionWindowPaneResolver.hidesChrome(for: currentPane) {
            hideWindowChrome()
        } else {
            revealWindowChrome()
        }
        toolbarOwner?.managedToolbar.validateVisibleItems()
        recomputeWindowMinSize()
    }

    private func hideWindowChrome() {
        guard chromeState != .hidden else { return }
        chromeState = .hidden

        resignFirstResponderInsideChrome()
        splitView.autosaveName = ""
        sidebarSplitItem.isCollapsed = true
        inspectorSplitItem.isCollapsed = true
        view.window?.recalculateKeyViewLoop()
    }

    private func revealWindowChrome() {
        guard chromeState != .revealed else { return }
        chromeState = .revealed

        sidebarSplitItem.isCollapsed = false
        restoreUserPaneLayout()
        view.window?.recalculateKeyViewLoop()
    }

    private func restoreUserPaneLayout() {
        splitView.autosaveName = splitAutosaveName
        applyDefaultCollapseStateIfNoAutosave()
    }

    /// A collapsed pane keeps whatever first responder it held, which would leave the window
    /// typing into a search field nobody can see.
    private func resignFirstResponderInsideChrome() {
        guard let window = view.window,
              let responder = window.firstResponder as? NSView else { return }
        guard responder.isDescendant(of: navigationSidebar.view)
            || responder.isDescendant(of: inspectorHosting.view) else { return }
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
