//
//  ContentView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import AppKit
import os
import SwiftUI
import TableProPluginKit

struct ContentView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ContentView")

    /// Payload identifying what this native window-tab should display.
    /// nil = default empty query tab (first window on connection).
    let payload: EditorTabPayload?

    @State private var currentSession: ConnectionSession?
    @State private var closingSessionId: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showNewConnectionSheet = false
    @State private var showEditConnectionSheet = false
    @State private var connectionToEdit: DatabaseConnection?
    @State private var connectionToDelete: DatabaseConnection?
    @State private var showDeleteConfirmation = false
    @State private var rightPanelState: RightPanelState?
    @State private var sessionState: SessionStateFactory.SessionState?
    @State private var inspectorContext = InspectorContext.empty
    @State private var windowTitle: String
    @Environment(\.openWindow)
    private var openWindow
    @Environment(AppState.self) private var appState

    private let storage = ConnectionStorage.shared

    init(payload: EditorTabPayload?) {
        self.payload = payload
        let defaultTitle: String
        if let tableName = payload?.tableName {
            defaultTitle = tableName
        } else if let connectionId = payload?.connectionId,
                  let connection = DatabaseManager.shared.activeSessions[connectionId]?.connection {
            let langName = PluginManager.shared.queryLanguageName(for: connection.type)
            defaultTitle = "\(langName) Query"
        } else {
            defaultTitle = "SQL Query"
        }
        _windowTitle = State(initialValue: defaultTitle)
    }

    var body: some View {
        mainContent
            .frame(minWidth: 1_200, minHeight: 600)
            .confirmationDialog(
                "Delete Connection",
                isPresented: $showDeleteConfirmation,
                presenting: connectionToDelete
            ) { connection in
                Button("Delete", role: .destructive) {
                    deleteConnection(connection)
                }
                Button("Cancel", role: .cancel) {}
            } message: { connection in
                Text("Are you sure you want to delete \"\(connection.name)\"?")
            }
            .onReceive(NotificationCenter.default.publisher(for: .newConnection)) { _ in
                openWindow(id: "connection-form", value: nil as UUID?)
            }
            // Right sidebar toggle is handled by MainContentView (has the binding)
            // Left sidebar toggle uses native NSSplitViewController.toggleSidebar via responder chain
            .onChange(of: DatabaseManager.shared.currentSessionId, initial: true) { _, newSessionId in
                guard closingSessionId == nil else { return }
                let ourConnectionId = payload?.connectionId
                if ourConnectionId != nil {
                    guard newSessionId == ourConnectionId else { return }
                } else {
                    guard currentSession == nil else { return }
                }

                if let connectionId = ourConnectionId ?? newSessionId {
                    currentSession = DatabaseManager.shared.activeSessions[connectionId]
                    columnVisibility = currentSession != nil ? .all : .detailOnly
                    if let session = currentSession {
                        if rightPanelState == nil {
                            rightPanelState = RightPanelState()
                        }
                        if sessionState == nil {
                            sessionState = SessionStateFactory.create(
                                connection: session.connection,
                                payload: payload
                            )
                        }
                        AppState.shared.isConnected = true
                        AppState.shared.safeModeLevel = session.connection.safeModeLevel
                        AppState.shared.editorLanguage = PluginManager.shared.editorLanguage(for: session.connection.type)
                        AppState.shared.currentDatabaseType = session.connection.type
                        AppState.shared.supportsDatabaseSwitching = PluginManager.shared.supportsDatabaseSwitching(
                            for: session.connection.type)
                    }
                } else {
                    currentSession = nil
                    columnVisibility = .detailOnly
                }
            }
            .task { handleConnectionStatusChange() }
            .onReceive(NotificationCenter.default.publisher(for: .connectionStatusDidChange)) { _ in
                handleConnectionStatusChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                // Only process notifications for our own window to avoid every
                // ContentView instance re-rendering on every window focus change.
                // Match by checking if the window is registered for our connectionId
                // in WindowLifecycleMonitor (subtitle may not be set yet on first appear).
                guard let notificationWindow = notification.object as? NSWindow,
                      let windowId = notificationWindow.identifier?.rawValue,
                      windowId == "main" || windowId.hasPrefix("main-"),
                      let connectionId = payload?.connectionId
                else { return }

                // Verify this notification is for our window. Check WindowLifecycleMonitor
                // first (reliable after onAppear registers), fall back to subtitle match
                // for the brief window before registration completes.
                let isOurWindow = WindowLifecycleMonitor.shared.windows(for: connectionId)
                    .contains(where: { $0 === notificationWindow })
                    || {
                        guard let name = currentSession?.connection.name, !name.isEmpty else { return false }
                        return notificationWindow.subtitle == name
                            || notificationWindow.subtitle == "\(name) — Preview"
                    }()
                guard isOurWindow else { return }

                if let session = DatabaseManager.shared.activeSessions[connectionId] {
                    AppState.shared.isConnected = true
                    AppState.shared.safeModeLevel = session.connection.safeModeLevel
                    AppState.shared.editorLanguage = PluginManager.shared.editorLanguage(for: session.connection.type)
                    AppState.shared.currentDatabaseType = session.connection.type
                    AppState.shared.supportsDatabaseSwitching = PluginManager.shared.supportsDatabaseSwitching(
                        for: session.connection.type)
                } else {
                    AppState.shared.isConnected = false
                    AppState.shared.safeModeLevel = .silent
                    AppState.shared.editorLanguage = .sql
                    AppState.shared.currentDatabaseType = nil
                    AppState.shared.supportsDatabaseSwitching = true
                }
            }
            .onChange(of: sessionState?.toolbarState.safeModeLevel) { _, newLevel in
                if let level = newLevel {
                    AppState.shared.safeModeLevel = level
                }
            }
    }

    // MARK: - View Components

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // MARK: - Sidebar (Left) - Table Browser
            if let currentSession = currentSession, let sessionState {
                VStack(spacing: 0) {
                    SidebarView(
                        tables: sessionTablesBinding,
                        sidebarState: SharedSidebarState.forConnection(currentSession.connection.id),
                        activeTableName: windowTitle,
                        onDoubleClick: { table in
                            let isView = table.type == .view
                            if let preview = WindowLifecycleMonitor.shared.previewWindow(for: currentSession.connection.id),
                               let previewCoordinator = MainContentCoordinator.coordinator(for: preview.windowId) {
                                // If the preview tab shows this table, promote it
                                if previewCoordinator.tabManager.selectedTab?.tableName == table.name {
                                    previewCoordinator.promotePreviewTab()
                                } else {
                                    // Preview shows a different table — promote it first, then open this table permanently
                                    previewCoordinator.promotePreviewTab()
                                    sessionState.coordinator.openTableTab(table.name, isView: isView)
                                }
                            } else {
                                // No preview tab — promote current if it's a preview, otherwise open permanently
                                sessionState.coordinator.promotePreviewTab()
                                sessionState.coordinator.openTableTab(table.name, isView: isView)
                            }
                        },
                        pendingTruncates: sessionPendingTruncatesBinding,
                        pendingDeletes: sessionPendingDeletesBinding,
                        tableOperationOptions: sessionTableOperationOptionsBinding,
                        databaseType: currentSession.connection.type,
                        connectionId: currentSession.connection.id,
                        schemaProvider: SchemaProviderRegistry.shared.provider(for: currentSession.connection.id),
                        coordinator: sessionState.coordinator
                    )
                }
                .searchable(
                    text: sidebarSearchTextBinding(for: currentSession.connection.id),
                    placement: .sidebar,
                    prompt: sidebarSearchPrompt(for: currentSession.connection.id)
                )
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 600)
            } else {
                Color.clear
                    .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 600)
            }
        } detail: {
            // MARK: - Detail (Main workspace with optional right sidebar)
            if let currentSession = currentSession, let rightPanelState, let sessionState {
                HStack(spacing: 0) {
                    MainContentView(
                        connection: currentSession.connection,
                        payload: payload,
                        windowTitle: $windowTitle,
                        tables: sessionTablesBinding,
                        sidebarState: SharedSidebarState.forConnection(currentSession.connection.id),
                        pendingTruncates: sessionPendingTruncatesBinding,
                        pendingDeletes: sessionPendingDeletesBinding,
                        tableOperationOptions: sessionTableOperationOptionsBinding,
                        inspectorContext: $inspectorContext,
                        rightPanelState: rightPanelState,
                        tabManager: sessionState.tabManager,
                        changeManager: sessionState.changeManager,
                        filterStateManager: sessionState.filterStateManager,
                        toolbarState: sessionState.toolbarState,
                        coordinator: sessionState.coordinator
                    )
                    .frame(maxWidth: .infinity)

                    if rightPanelState.isPresented {
                        PanelResizeHandle(panelWidth: Bindable(rightPanelState).panelWidth)
                        Divider()
                        UnifiedRightPanelView(
                            state: rightPanelState,
                            inspectorContext: inspectorContext,
                            connection: currentSession.connection,
                            tables: currentSession.tables
                        )
                        .frame(width: rightPanelState.panelWidth)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: rightPanelState.isPresented)
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
        .navigationTitle(windowTitle)
        .navigationSubtitle(currentSession?.connection.name ?? "")
    }

    // Removed: newConnectionSheet and editConnectionSheet helpers
    // Connection forms are now handled by the separate connection-form window

    // MARK: - Session State Bindings

    /// Generic helper to create bindings that update session state
    private func createSessionBinding<T>(
        get: @escaping (ConnectionSession) -> T,
        set: @escaping (inout ConnectionSession, T) -> Void,
        defaultValue: T
    ) -> Binding<T> {
        Binding(
            get: {
                guard let session = currentSession else {
                    return defaultValue
                }
                return get(session)
            },
            set: { newValue in
                guard let sessionId = payload?.connectionId ?? currentSession?.id else { return }
                Task { @MainActor in
                    DatabaseManager.shared.updateSession(sessionId) { session in
                        set(&session, newValue)
                    }
                }
            }
        )
    }

    private var sessionTablesBinding: Binding<[TableInfo]> {
        createSessionBinding(
            get: { $0.tables },
            set: { $0.tables = $1 },
            defaultValue: []
        )
    }

    private var sessionPendingTruncatesBinding: Binding<Set<String>> {
        createSessionBinding(
            get: { $0.pendingTruncates },
            set: { $0.pendingTruncates = $1 },
            defaultValue: []
        )
    }

    private var sessionPendingDeletesBinding: Binding<Set<String>> {
        createSessionBinding(
            get: { $0.pendingDeletes },
            set: { $0.pendingDeletes = $1 },
            defaultValue: []
        )
    }

    private func sidebarSearchTextBinding(for connectionId: UUID) -> Binding<String> {
        let state = SharedSidebarState.forConnection(connectionId)
        return Binding(
            get: { state.searchText },
            set: { state.searchText = $0 }
        )
    }

    private func sidebarSearchPrompt(for connectionId: UUID) -> String {
        let state = SharedSidebarState.forConnection(connectionId)
        switch state.selectedSidebarTab {
        case .tables:
            return String(localized: "Filter")
        case .favorites:
            return String(localized: "Filter favorites")
        }
    }

    private var sessionTableOperationOptionsBinding: Binding<[String: TableOperationOptions]> {
        createSessionBinding(
            get: { $0.tableOperationOptions },
            set: { $0.tableOperationOptions = $1 },
            defaultValue: [:]
        )
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
                closingSessionId = sid
                rightPanelState?.teardown()
                rightPanelState = nil
                sessionState?.coordinator.teardown()
                sessionState = nil
                currentSession = nil
                columnVisibility = .detailOnly
                AppState.shared.isConnected = false
                AppState.shared.safeModeLevel = .silent
                AppState.shared.editorLanguage = .sql
                AppState.shared.currentDatabaseType = nil
                AppState.shared.supportsDatabaseSwitching = true

                let tabbingId = "com.TablePro.main.\(sid.uuidString)"
                DispatchQueue.main.async {
                    for window in NSApp.windows where window.tabbingIdentifier == tabbingId {
                        window.isReleasedWhenClosed = true
                        window.close()
                    }
                }
            }
            return
        }
        if let existing = currentSession,
           existing.isContentViewEquivalent(to: newSession) {
            return
        }
        currentSession = newSession
        if rightPanelState == nil {
            rightPanelState = RightPanelState()
        }
        if sessionState == nil {
            sessionState = SessionStateFactory.create(
                connection: newSession.connection,
                payload: payload
            )
        }
        AppState.shared.isConnected = true
        AppState.shared.safeModeLevel = newSession.connection.safeModeLevel
        AppState.shared.editorLanguage = PluginManager.shared.editorLanguage(for: newSession.connection.type)
        AppState.shared.currentDatabaseType = newSession.connection.type
        AppState.shared.supportsDatabaseSwitching = PluginManager.shared.supportsDatabaseSwitching(
            for: newSession.connection.type)
    }

    // MARK: - Actions

    private func connectToDatabase(_ connection: DatabaseConnection) {
        Task {
            do {
                try await DatabaseManager.shared.connectToSession(connection)
            } catch {
                Self.logger.error("Failed to connect: \(error.localizedDescription)")
            }
        }
    }

    private func handleCloseSession(_ sessionId: UUID) {
        Task {
            await DatabaseManager.shared.disconnectSession(sessionId)
        }
    }

    private func saveCurrentSessionState() {
        // State is automatically saved through bindings
    }

    // MARK: - Persistence

    private func deleteConnection(_ connection: DatabaseConnection) {
        if DatabaseManager.shared.activeSessions[connection.id] != nil {
            Task {
                await DatabaseManager.shared.disconnectSession(connection.id)
            }
        }

        storage.deleteConnection(connection)
    }
}

#Preview {
    ContentView(payload: nil)
}
