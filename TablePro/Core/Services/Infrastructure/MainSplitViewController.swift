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
import os
import SwiftUI

@MainActor
internal final class MainSplitViewController: NSSplitViewController, InspectorVisibilityProxy {
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    // MARK: - Payload & Session

    let payload: EditorTabPayload?
    private var currentSession: ConnectionSession?
    private var sessionState: SessionStateFactory.SessionState?
    private var rightPanelState: RightPanelState?
    private var closingSessionId: UUID?

    var windowTitle: String {
        didSet { view.window?.title = windowTitle }
    }

    // MARK: - Split View Items

    private var sidebarSplitItem: NSSplitViewItem!
    private var detailSplitItem: NSSplitViewItem!
    private var inspectorSplitItem: NSSplitViewItem!

    private var sidebarContainer: SidebarContainerViewController!
    private var detailHosting: NSHostingController<AnyView>!
    private var inspectorHosting: NSHostingController<AnyView>!

    // MARK: - Toolbar

    private var toolbarOwner: MainWindowToolbar?

    // MARK: - Observers

    private var connectionStatusObserver: NSObjectProtocol?
    private var newConnectionObserver: NSObjectProtocol?

    // MARK: - Init

    init(payload: EditorTabPayload?, sessionState: SessionStateFactory.SessionState?) {
        self.payload = payload

        let defaultTitle: String
        if payload?.tabType == .serverDashboard {
            defaultTitle = String(localized: "Server Dashboard")
        } else if payload?.tabType == .erDiagram {
            defaultTitle = String(localized: "ER Diagram")
        } else if payload?.tabType == .createTable {
            defaultTitle = String(localized: "Create Table")
        } else if payload?.tabType == .terminal {
            defaultTitle = String(localized: "Terminal")
        } else if let tabTitle = payload?.tabTitle {
            defaultTitle = tabTitle
        } else if let tableName = payload?.tableName {
            defaultTitle = tableName
        } else if let connectionId = payload?.connectionId,
                  let connection = DatabaseManager.shared.activeSessions[connectionId]?.connection {
            let langName = PluginManager.shared.queryLanguageName(for: connection.type)
            defaultTitle = "\(langName) Query"
        } else {
            defaultTitle = String(localized: "SQL Query")
        }
        self.windowTitle = defaultTitle

        var resolvedSession: ConnectionSession?
        if let connectionId = payload?.connectionId {
            resolvedSession = DatabaseManager.shared.activeSessions[connectionId]
        } else if let currentId = DatabaseManager.shared.currentSessionId {
            resolvedSession = DatabaseManager.shared.activeSessions[currentId]
        }
        self.currentSession = resolvedSession

        if let session = resolvedSession {
            self.rightPanelState = RightPanelState()
            let state: SessionStateFactory.SessionState
            if let payloadId = payload?.id,
               let pending = SessionStateFactory.consumePending(for: payloadId) {
                state = pending
                Self.lifecycleLogger.info(
                    "[open] MainSplitVC.init consumed pending payloadId=\(payloadId, privacy: .public)"
                )
            } else {
                state = SessionStateFactory.create(connection: session.connection, payload: payload)
            }
            self.sessionState = state
            if payload?.intent == .newEmptyTab,
               let tabTitle = state.coordinator.tabManager.selectedTab?.title {
                self.windowTitle = tabTitle
            }
        }

        super.init(nibName: nil, bundle: nil)
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
        splitView.autosaveName = "com.TablePro.mainSplit"

        sidebarContainer = SidebarContainerViewController(rootView: AnyView(buildSidebarView()))
        sidebarSplitItem = NSSplitViewItem(sidebarWithViewController: sidebarContainer)
        sidebarSplitItem.canCollapse = true
        sidebarSplitItem.minimumThickness = 280
        sidebarSplitItem.maximumThickness = 600
        addSplitViewItem(sidebarSplitItem)

        detailHosting = NSHostingController(rootView: AnyView(buildDetailView()))
        detailSplitItem = NSSplitViewItem(viewController: detailHosting)
        detailSplitItem.minimumThickness = 400
        detailSplitItem.holdingPriority = .defaultLow
        addSplitViewItem(detailSplitItem)

        inspectorHosting = NSHostingController(rootView: AnyView(buildInspectorView()))
        inspectorSplitItem = NSSplitViewItem(inspectorWithViewController: inspectorHosting)
        inspectorSplitItem.canCollapse = true
        inspectorSplitItem.minimumThickness = 280
        inspectorSplitItem.maximumThickness = 500
        addSplitViewItem(inspectorSplitItem)

        if currentSession == nil {
            sidebarSplitItem.isCollapsed = true
        } else {
            sidebarContainer.updateSidebarState(
                SharedSidebarState.forConnection(currentSession!.connection.id) // swiftlint:disable:this force_unwrapping
            )
        }
        inspectorSplitItem.isCollapsed = !UserDefaults.standard.bool(forKey: Self.inspectorPresentedKey)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard let window = view.window else { return }

        let defaultSize = NSSize(width: 1_200, height: 800)
        if window.frame.width < defaultSize.width || window.frame.height < defaultSize.height {
            window.setContentSize(NSSize(
                width: max(window.frame.width, defaultSize.width),
                height: max(window.frame.height, defaultSize.height)
            ))
            window.center()
        }

        window.title = windowTitle
        if let session = currentSession {
            window.subtitle = session.connection.name
        }

        if let sessionState {
            sessionState.coordinator.inspectorProxy = self
            sessionState.coordinator.splitViewController = self
            installToolbar(coordinator: sessionState.coordinator)
        }

        if let currentSession {
            sidebarContainer.updateSidebarState(
                SharedSidebarState.forConnection(currentSession.connection.id)
            )
        }

        installObservers()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        removeObservers()
    }

    // MARK: - Observers

    private func installObservers() {
        guard connectionStatusObserver == nil else { return }
        connectionStatusObserver = NotificationCenter.default.addObserver(
            forName: .connectionStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConnectionStatusChange()
            }
        }
        newConnectionObserver = NotificationCenter.default.addObserver(
            forName: .newConnection,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NotificationCenter.default.post(name: .openWelcomeWindow, object: nil)
            }
        }
        handleConnectionStatusChange()
    }

    private func removeObservers() {
        if let observer = connectionStatusObserver {
            NotificationCenter.default.removeObserver(observer)
            connectionStatusObserver = nil
        }
        if let observer = newConnectionObserver {
            NotificationCenter.default.removeObserver(observer)
            newConnectionObserver = nil
        }
    }

    // MARK: - Toolbar

    func installToolbar(coordinator: MainContentCoordinator) {
        guard let window = view.window else { return }
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

    private func handleConnectionStatusChange() {
        guard closingSessionId == nil else { return }

        let sessions = DatabaseManager.shared.activeSessions
        let connectionId = payload?.connectionId ?? currentSession?.id ?? DatabaseManager.shared.currentSessionId

        guard let sid = connectionId else {
            if currentSession != nil { currentSession = nil }
            return
        }

        guard let newSession = sessions[sid] else {
            if currentSession?.id == sid {
                Self.lifecycleLogger.info(
                    "[close] MainSplitVC session removed connId=\(sid, privacy: .public)"
                )
                closingSessionId = sid
                rightPanelState?.teardown()
                rightPanelState = nil
                sessionState?.coordinator.teardown()
                sessionState = nil
                currentSession = nil
                sidebarContainer.updateSidebarState(nil)
                if view.window?.isVisible == true {
                    sidebarSplitItem.animator().isCollapsed = true
                } else {
                    sidebarSplitItem.isCollapsed = true
                }
            }
            return
        }

        if let existing = currentSession, existing.isContentViewEquivalent(to: newSession) {
            return
        }
        currentSession = newSession

        if payload?.tableName == nil,
           windowTitle == String(localized: "SQL Query") || windowTitle.hasSuffix(" Query") {
            windowTitle = newSession.connection.name
        }
        view.window?.subtitle = newSession.connection.name

        if rightPanelState == nil {
            rightPanelState = RightPanelState()
        }
        if sessionState == nil {
            let state = SessionStateFactory.create(connection: newSession.connection, payload: payload)
            sessionState = state
            state.coordinator.inspectorProxy = self
            state.coordinator.splitViewController = self
            installToolbar(coordinator: state.coordinator)
        }

        if view.window?.isVisible == true {
            sidebarSplitItem.animator().isCollapsed = false
        } else {
            sidebarSplitItem.isCollapsed = false
        }
        rebuildPanes()
    }

    // MARK: - Pane Construction

    private func rebuildPanes() {
        sidebarContainer.rootView = AnyView(buildSidebarView())
        if let currentSession {
            sidebarContainer.updateSidebarState(
                SharedSidebarState.forConnection(currentSession.connection.id)
            )
        }
        detailHosting.rootView = AnyView(buildDetailView())
        inspectorHosting.rootView = AnyView(buildInspectorView())
    }

    @ViewBuilder
    private func buildSidebarView() -> some View {
        if let currentSession, let sessionState {
            SidebarView(
                tables: sessionTablesBinding,
                sidebarState: SharedSidebarState.forConnection(currentSession.connection.id),
                onDoubleClick: { [weak self] table in
                    guard let coordinator = self?.sessionState?.coordinator else { return }
                    let connectionId = coordinator.connectionId
                    let isView = table.type == .view
                    if let preview = WindowLifecycleMonitor.shared.previewWindow(for: connectionId),
                       let previewCoordinator = MainContentCoordinator.coordinator(for: preview.windowId) {
                        if previewCoordinator.tabManager.selectedTab?.tableName == table.name {
                            previewCoordinator.promotePreviewTab()
                        } else {
                            previewCoordinator.promotePreviewTab()
                            coordinator.openTableTab(table.name, isView: isView)
                        }
                    } else {
                        coordinator.promotePreviewTab()
                        coordinator.openTableTab(table.name, isView: isView)
                    }
                },
                pendingTruncates: sessionPendingTruncatesBinding,
                pendingDeletes: sessionPendingDeletesBinding,
                tableOperationOptions: sessionTableOperationOptionsBinding,
                databaseType: currentSession.connection.type,
                connectionId: currentSession.connection.id,
                coordinator: sessionState.coordinator
            )
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func buildDetailView() -> some View {
        if let currentSession, let rightPanelState, let sessionState {
            MainContentView(
                connection: currentSession.connection,
                payload: payload,
                windowTitle: windowTitleBinding,
                tables: sessionTablesBinding,
                sidebarState: SharedSidebarState.forConnection(currentSession.connection.id),
                pendingTruncates: sessionPendingTruncatesBinding,
                pendingDeletes: sessionPendingDeletesBinding,
                tableOperationOptions: sessionTableOperationOptionsBinding,
                rightPanelState: rightPanelState,
                tabManager: sessionState.tabManager,
                changeManager: sessionState.changeManager,
                filterStateManager: sessionState.filterStateManager,
                toolbarState: sessionState.toolbarState,
                coordinator: sessionState.coordinator
            )
            .transaction { $0.animation = nil }
        } else {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Connecting...")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func buildInspectorView() -> some View {
        if let currentSession, let rightPanelState {
            UnifiedRightPanelView(
                state: rightPanelState,
                connection: currentSession.connection,
                tables: currentSession.tables
            )
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            Color.clear
        }
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

    private var sessionTablesBinding: Binding<[TableInfo]> {
        createSessionBinding(get: { $0.tables }, set: { $0.tables = $1 }, defaultValue: [])
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

    // MARK: - InspectorVisibilityProxy

    var isInspectorVisible: Bool {
        guard let inspectorSplitItem else { return false }
        return !inspectorSplitItem.isCollapsed
    }

    func showInspector() {
        inspectorSplitItem?.animator().isCollapsed = false
        UserDefaults.standard.set(true, forKey: Self.inspectorPresentedKey)
    }

    func hideInspector() {
        inspectorSplitItem?.animator().isCollapsed = true
        UserDefaults.standard.set(false, forKey: Self.inspectorPresentedKey)
    }

    // MARK: - Sidebar

    var isSidebarCollapsed: Bool {
        sidebarSplitItem?.isCollapsed ?? true
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
    }

    // MARK: - Constants

    private static let inspectorPresentedKey = "com.TablePro.rightPanel.isPresented"
}
