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

    let payload: EditorTabPayload?
    private let payloadConnection: DatabaseConnection?
    private var currentSession: ConnectionSession?
    private var sessionState: SessionStateFactory.SessionState?
    private var rightPanelState: RightPanelState?
    private var closingSessionId: UUID?

    var windowTitle: String {
        didSet { view.window?.title = windowTitle }
    }

    var windowSubtitle: String {
        didSet { view.window?.subtitle = windowSubtitle }
    }

    // MARK: - Split View Items

    private var sidebarSplitItem: NSSplitViewItem!
    private var detailSplitItem: NSSplitViewItem!
    private var inspectorSplitItem: NSSplitViewItem!

    private var sidebarContainer: SidebarContainerViewController!
    private var detailHosting: NSHostingController<AnyView>!
    private var inspectorHosting: NSHostingController<AnyView>!

    // MARK: - Panel Layout State

    private var splitAutosaveName: NSSplitView.AutosaveName {
        if let connectionId = payload?.connectionId ?? currentSession?.connection.id {
            return "com.TablePro.mainSplit.\(connectionId.uuidString)"
        }
        return "com.TablePro.mainSplit"
    }

    // MARK: - Toolbar

    private var toolbarOwner: MainWindowToolbar?

    // MARK: - Observers

    private var connectionStatusCancellable: AnyCancellable?

    // MARK: - Title Resolution

    static func resolveDefaultTitle(payload: EditorTabPayload?, queryLanguageName: String?) -> String {
        switch payload?.tabType {
        case .serverDashboard:
            return String(localized: "Server Dashboard")
        case .erDiagram:
            return String(localized: "ER Diagram")
        case .createTable:
            return String(localized: "Create Table")
        default:
            break
        }
        if let tabTitle = payload?.tabTitle {
            return tabTitle
        }
        if let sourceFileURL = payload?.sourceFileURL {
            return QueryTab.fileDisplayTitle(for: sourceFileURL)
        }
        if let tableName = payload?.tableName {
            return tableName
        }
        if let queryLanguageName {
            return String(format: String(localized: "%@ Query"), queryLanguageName)
        }
        return String(localized: "SQL Query")
    }

    static func resolveDefaultSubtitle(tab: QueryTab?, connection: DatabaseConnection) -> String {
        tableSubtitle(
            isTable: tab?.tabType == .table,
            tableName: tab?.tableContext.tableName,
            databaseName: tab?.tableContext.databaseName ?? "",
            schemaName: tab?.tableContext.schemaName,
            fallback: connection.name
        )
    }

    static func resolveDefaultSubtitle(payload: EditorTabPayload?, connection: DatabaseConnection) -> String {
        tableSubtitle(
            isTable: payload?.tabType == .table,
            tableName: payload?.tableName,
            databaseName: payload?.databaseName ?? "",
            schemaName: payload?.schemaName,
            fallback: connection.name
        )
    }

    private static func tableSubtitle(
        isTable: Bool,
        tableName: String?,
        databaseName: String,
        schemaName: String?,
        fallback: String
    ) -> String {
        guard isTable, let tableName, !tableName.isEmpty, !databaseName.isEmpty else { return fallback }
        if let schemaName, !schemaName.isEmpty {
            return "\(databaseName) · \(schemaName)"
        }
        return databaseName
    }

    // MARK: - Init

    init(payload: EditorTabPayload?, sessionState: SessionStateFactory.SessionState?) {
        self.payload = payload
        if let connectionId = payload?.connectionId {
            self.payloadConnection = DatabaseManager.shared.activeSessions[connectionId]?.connection
                ?? ConnectionStorage.shared.loadConnections().first { $0.id == connectionId }
        } else {
            self.payloadConnection = nil
        }

        let queryLanguageName: String? = {
            guard let connectionId = payload?.connectionId,
                  let connection = DatabaseManager.shared.activeSessions[connectionId]?.connection else {
                return nil
            }
            return PluginManager.shared.queryLanguageName(for: connection.type)
        }()
        self.windowTitle = Self.resolveDefaultTitle(payload: payload, queryLanguageName: queryLanguageName)

        var resolvedSession: ConnectionSession?
        if let connectionId = payload?.connectionId {
            resolvedSession = DatabaseManager.shared.activeSessions[connectionId]
        } else if let currentId = DatabaseManager.shared.currentSessionId {
            resolvedSession = DatabaseManager.shared.activeSessions[currentId]
        }
        self.currentSession = resolvedSession

        let subtitleConnection = self.payloadConnection ?? resolvedSession?.connection
        if let subtitleConnection {
            self.windowSubtitle = Self.resolveDefaultSubtitle(payload: payload, connection: subtitleConnection)
        } else {
            self.windowSubtitle = ""
        }

        if let session = resolvedSession {
            self.rightPanelState = RightPanelState(connectionId: session.connection.id)
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

        sidebarContainer = SidebarContainerViewController(rootView: AnyView(Color.clear))
        sidebarSplitItem = NSSplitViewItem(sidebarWithViewController: sidebarContainer)
        sidebarSplitItem.canCollapse = true
        sidebarSplitItem.minimumThickness = Self.sidebarMinThickness
        sidebarSplitItem.maximumThickness = Self.sidebarMaxThickness
        addSplitViewItem(sidebarSplitItem)

        detailHosting = NSHostingController(rootView: AnyView(Color.clear))
        detailSplitItem = NSSplitViewItem(viewController: detailHosting)
        detailSplitItem.minimumThickness = Self.detailMinThickness
        detailSplitItem.holdingPriority = .defaultLow
        addSplitViewItem(detailSplitItem)

        inspectorHosting = NSHostingController(rootView: AnyView(Color.clear))
        inspectorSplitItem = NSSplitViewItem(inspectorWithViewController: inspectorHosting)
        inspectorSplitItem.canCollapse = true
        inspectorSplitItem.minimumThickness = Self.inspectorMinThickness
        inspectorSplitItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        addSplitViewItem(inspectorSplitItem)

        splitView.autosaveName = splitAutosaveName
        applyDefaultCollapseStateIfNoAutosave()

        rebuildPanes()
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        recomputeWindowMinSize()
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

        if let currentSession, let coordinator = sessionState?.coordinator {
            sidebarContainer.updateSidebarState(
                SharedSidebarState.forConnection(currentSession.connection.id),
                windowState: coordinator.windowSidebarState
            )
        }

        installObservers()
        recomputeWindowMinSize()
        window.recalculateKeyViewLoop()
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
                sidebarContainer.updateSidebarState(nil, windowState: nil)
                sidebarContainer.rootView = AnyView(buildSidebarView())
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
            windowSubtitle = newSession.connection.name
        }

        if rightPanelState == nil {
            rightPanelState = RightPanelState(connectionId: newSession.connection.id)
        }
        if sessionState == nil {
            let state = SessionStateFactory.create(connection: newSession.connection, payload: payload)
            sessionState = state
            state.coordinator.inspectorProxy = self
            state.coordinator.splitViewController = self
            installToolbar(coordinator: state.coordinator)
        }

        rebuildPanes()
    }

    // MARK: - Pane Construction

    private func rebuildPanes() {
        sidebarContainer.rootView = AnyView(buildSidebarView())
        if let currentSession, let coordinator = sessionState?.coordinator {
            sidebarContainer.updateSidebarState(
                SharedSidebarState.forConnection(currentSession.connection.id),
                windowState: coordinator.windowSidebarState
            )
        }
        detailHosting.rootView = AnyView(buildDetailView())
        inspectorHosting.rootView = AnyView(buildInspectorView())
    }

    @ViewBuilder
    private func buildSidebarView() -> some View {
        if let currentSession, let sessionState {
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
        if let pendingConnection = connectingConnection {
            ConnectingStateView(connection: pendingConnection) { [weak self] in
                self?.cancelConnectionAttempt()
            }
        } else if let currentSession, let rightPanelState, let sessionState {
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
            .transaction { $0.animation = nil }
        } else {
            Color.clear
        }
    }

    private var connectingConnection: DatabaseConnection? {
        guard closingSessionId == nil else { return nil }
        guard let connectionId = payload?.connectionId else { return nil }
        if let session = DatabaseManager.shared.activeSessions[connectionId] {
            return session.driver == nil ? session.connection : nil
        }
        return payloadConnection
    }

    private func cancelConnectionAttempt() {
        view.window?.performClose(nil)
    }

    @ViewBuilder
    private func buildInspectorView() -> some View {
        if let currentSession, let rightPanelState {
            UnifiedRightPanelView(
                state: rightPanelState,
                connection: currentSession.connection
            )
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
        inspectorHosting.rootView = AnyView(buildInspectorView())
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

    // MARK: - Sidebar

    var isSidebarCollapsed: Bool {
        sidebarSplitItem?.isCollapsed ?? true
    }

    func focusSidebarSearch() {
        if sidebarSplitItem?.isCollapsed == true {
            sidebarSplitItem?.animator().isCollapsed = false
        }
        sidebarContainer.focusSearchField()
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

    // MARK: - Dynamic Window Minimum Size

    private static let baseWindowMinWidth: CGFloat = 720
    private static let baseWindowMinHeight: CGFloat = 480
    private static let sidebarMinThickness: CGFloat = 280
    private static let sidebarMaxThickness: CGFloat = 600
    private static let detailMinThickness: CGFloat = 400
    private static let inspectorMinThickness: CGFloat = 270

    private func recomputeWindowMinSize() {
        guard let window = view.window else { return }
        let sidebarVisible = !(sidebarSplitItem?.isCollapsed ?? true)
        let inspectorVisible = !(inspectorSplitItem?.isCollapsed ?? true)

        let detailMin = Self.detailMinThickness
        let sidebarMin = Self.sidebarMinThickness
        let inspectorMin = Self.inspectorMinThickness
        let dividerThickness = splitView.dividerThickness

        var width: CGFloat = detailMin
        if sidebarVisible {
            width += sidebarMin + dividerThickness
        }
        if inspectorVisible {
            width += inspectorMin + dividerThickness
        }

        let resolvedWidth = max(Self.baseWindowMinWidth, width)
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

    private func applyDefaultCollapseStateIfNoAutosave() {
        let key = "NSSplitView Subview Frames \(splitAutosaveName)"
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        inspectorSplitItem.isCollapsed = true
    }
}
