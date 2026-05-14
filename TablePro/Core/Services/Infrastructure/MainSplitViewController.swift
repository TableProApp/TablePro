//
//  MainSplitViewController.swift
//  TablePro
//
//  NSSplitViewController replacing NavigationSplitView for native sidebar/inspector.
//  One instance per connection window, created once and never rebuilt. Manages
//  three panes (sidebar, detail, inspector) and serves as
//  window.contentViewController so .toggleSidebar and .sidebarTrackingSeparator
//  work via the responder chain.
//

import AppKit
import Combine
import os
import SwiftUI

@MainActor
internal final class MainSplitViewController: NSSplitViewController, InspectorVisibilityProxy {
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    // MARK: - Connection & Session

    private let connection: DatabaseConnection
    private let sessionState: SessionStateFactory.SessionState
    private var coordinator: MainContentCoordinator { sessionState.coordinator }
    private var rightPanelState: RightPanelState { sessionState.rightPanelState }
    private var didTeardown = false

    // MARK: - Split View Items

    private var sidebarSplitItem: NSSplitViewItem!
    private var detailSplitItem: NSSplitViewItem!
    private var inspectorSplitItem: NSSplitViewItem!

    private var sidebarContainer: SidebarContainerViewController!
    private var detailHosting: NSHostingController<AnyView>!
    private var inspectorHosting: NSHostingController<AnyView>!
    private var hasMaterializedInspector = false

    // MARK: - Toolbar

    private var toolbarOwner: MainWindowToolbar?

    // MARK: - Observers

    private var connectionStatusCancellable: AnyCancellable?

    // MARK: - Init

    init(connection: DatabaseConnection, sessionState: SessionStateFactory.SessionState) {
        self.connection = connection
        self.sessionState = sessionState
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
        splitView.autosaveName = "com.TablePro.mainSplit.\(connection.id.uuidString)"

        coordinator.inspectorProxy = self
        coordinator.splitViewController = self

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

        let inspectorPresented = UserDefaults.standard.bool(forKey: inspectorPresentedKey)
        let initialInspectorContent: AnyView
        if inspectorPresented {
            initialInspectorContent = AnyView(buildInspectorView())
            hasMaterializedInspector = true
        } else {
            initialInspectorContent = AnyView(Color.clear)
        }
        inspectorHosting = NSHostingController(rootView: initialInspectorContent)
        inspectorSplitItem = NSSplitViewItem(inspectorWithViewController: inspectorHosting)
        inspectorSplitItem.canCollapse = true
        inspectorSplitItem.minimumThickness = 270
        inspectorSplitItem.maximumThickness = 400
        addSplitViewItem(inspectorSplitItem)

        if isConnected {
            sidebarContainer.updateSidebarState(
                SharedSidebarState.forConnection(connection.id),
                windowState: coordinator.windowSidebarState
            )
        } else {
            sidebarSplitItem.isCollapsed = true
        }
        inspectorSplitItem.isCollapsed = !inspectorPresented
    }

    private var isConnected: Bool {
        DatabaseManager.shared.activeSessions[connection.id]?.driver != nil
    }

    private func materializeInspectorIfNeeded() {
        guard !hasMaterializedInspector, let inspectorHosting else { return }
        hasMaterializedInspector = true
        inspectorHosting.rootView = AnyView(buildInspectorView())
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard let window = view.window else { return }

        window.subtitle = connection.name

        installToolbar(coordinator: coordinator)

        if isConnected {
            sidebarContainer.updateSidebarState(
                SharedSidebarState.forConnection(connection.id),
                windowState: coordinator.windowSidebarState
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
        guard connectionStatusCancellable == nil else { return }
        connectionStatusCancellable = AppEvents.shared.connectionStatusChanged
            .receive(on: RunLoop.main)
            .filter { [weak self] payload in
                payload.connectionId == self?.connection.id
            }
            .sink { [weak self] _ in
                self?.handleConnectionStatusChange()
            }
        handleConnectionStatusChange()
    }

    private func removeObservers() {
        connectionStatusCancellable = nil
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

    /// The connection window is created once per connection. This handler only
    /// reacts to the driver becoming available (rebuild panes out of the
    /// connecting state, expand the sidebar) or the session being torn down.
    private func handleConnectionStatusChange() {
        guard !didTeardown else { return }

        let session = DatabaseManager.shared.activeSessions[connection.id]
        guard session != nil else {
            Self.lifecycleLogger.info(
                "[close] MainSplitVC session removed connId=\(self.connection.id, privacy: .public)"
            )
            didTeardown = true
            sidebarContainer.updateSidebarState(nil, windowState: nil)
            if view.window?.isVisible == true {
                sidebarSplitItem.animator().isCollapsed = true
            } else {
                sidebarSplitItem.isCollapsed = true
            }
            return
        }

        let connected = session?.driver != nil
        if view.window?.isVisible == true {
            sidebarSplitItem.animator().isCollapsed = !connected
        } else {
            sidebarSplitItem.isCollapsed = !connected
        }
        if connected {
            sidebarContainer.updateSidebarState(
                SharedSidebarState.forConnection(connection.id),
                windowState: coordinator.windowSidebarState
            )
        }
        rebuildPanes()
    }

    // MARK: - Pane Construction

    private func rebuildPanes() {
        sidebarContainer.rootView = AnyView(buildSidebarView())
        if isConnected {
            sidebarContainer.updateSidebarState(
                SharedSidebarState.forConnection(connection.id),
                windowState: coordinator.windowSidebarState
            )
        }
        detailHosting.rootView = AnyView(buildDetailView())
        inspectorHosting.rootView = AnyView(buildInspectorView())
    }

    @ViewBuilder
    private func buildSidebarView() -> some View {
        if isConnected {
            sidebarBody()
                .transaction { $0.animation = nil }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func sidebarBody() -> some View {
        SidebarView(
            sidebarState: SharedSidebarState.forConnection(connection.id),
            onDoubleClick: { [weak self] table in
                guard let self else { return }
                let isView = table.type == .view
                self.coordinator.promotePreviewTab()
                self.coordinator.openTableTab(table.name, isView: isView)
            },
            pendingTruncates: sessionPendingTruncatesBinding,
            pendingDeletes: sessionPendingDeletesBinding,
            tableOperationOptions: sessionTableOperationOptionsBinding,
            databaseType: connection.type,
            connectionId: connection.id,
            coordinator: coordinator
        )
    }

    @ViewBuilder
    private func buildDetailView() -> some View {
        if let pendingConnection = connectingConnection {
            ConnectingStateView(connection: pendingConnection) { [weak self] in
                self?.cancelConnectionAttempt()
            }
        } else {
            ConnectionSplitContainerView(
                connection: connection,
                sidebarState: SharedSidebarState.forConnection(connection.id),
                pendingTruncates: sessionPendingTruncatesBinding,
                pendingDeletes: sessionPendingDeletesBinding,
                tableOperationOptions: sessionTableOperationOptionsBinding,
                rightPanelState: rightPanelState,
                tabManager: sessionState.tabManager,
                changeManager: sessionState.changeManager,
                toolbarState: sessionState.toolbarState,
                coordinator: coordinator
            )
            .transaction { $0.animation = nil }
        }
    }

    private var connectingConnection: DatabaseConnection? {
        guard !didTeardown else { return nil }
        if let session = DatabaseManager.shared.activeSessions[connection.id] {
            return session.driver == nil ? session.connection : nil
        }
        return connection
    }

    private func cancelConnectionAttempt() {
        view.window?.performClose(nil)
    }

    @ViewBuilder
    private func buildInspectorView() -> some View {
        UnifiedRightPanelView(
            state: rightPanelState,
            connection: connection
        )
    }

    // MARK: - Session Bindings

    private func createSessionBinding<T>(
        get: @escaping (ConnectionSession) -> T,
        set: @escaping (inout ConnectionSession, T) -> Void,
        defaultValue: T
    ) -> Binding<T> {
        Binding(
            get: { [weak self] in
                guard let self,
                      let session = DatabaseManager.shared.activeSessions[self.connection.id]
                else { return defaultValue }
                return get(session)
            },
            set: { [weak self] newValue in
                guard let self else { return }
                let connectionId = self.connection.id
                Task {
                    DatabaseManager.shared.updateSession(connectionId) { session in
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

    // MARK: - InspectorVisibilityProxy

    var isInspectorVisible: Bool {
        guard let inspectorSplitItem else { return false }
        return !inspectorSplitItem.isCollapsed
    }

    func showInspector() {
        materializeInspectorIfNeeded()
        inspectorSplitItem?.animator().isCollapsed = false
        UserDefaults.standard.set(true, forKey: inspectorPresentedKey)
    }

    func hideInspector() {
        inspectorSplitItem?.animator().isCollapsed = true
        UserDefaults.standard.set(false, forKey: inspectorPresentedKey)
    }

    @objc override func toggleInspector(_ sender: Any?) {
        toggleInspector()
    }

    // MARK: - Sidebar

    var isSidebarCollapsed: Bool {
        sidebarSplitItem?.isCollapsed ?? true
    }

    func setSidebarTab(_ tab: SidebarTab) {
        let sidebarState = SharedSidebarState.forConnection(connection.id)

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

    private var inspectorPresentedKey: String {
        "com.TablePro.rightPanel.isPresented.\(connection.id.uuidString)"
    }
}
