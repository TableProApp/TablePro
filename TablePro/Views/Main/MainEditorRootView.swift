//
//  MainEditorRootView.swift
//  TablePro
//

import SwiftUI

internal struct MainEditorRootView: View {
    @Bindable var windowState: MainEditorWindowState

    var body: some View {
        NavigationSplitView(columnVisibility: $windowState.sidebarColumnVisibility) {
            sidebarColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 600)
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $windowState.inspectorPresented) {
            inspectorColumn
                .inspectorColumnWidth(min: 270, ideal: 320, max: 400)
        }
    }

    @ViewBuilder
    private var sidebarColumn: some View {
        if let session = windowState.currentSession,
           let coordinator = windowState.sessionState?.coordinator {
            let sidebarState = SharedSidebarState.forConnection(session.connection.id)
            SidebarView(
                sidebarState: sidebarState,
                onDoubleClick: { table in
                    handleSidebarDoubleClick(table: table, coordinator: coordinator)
                },
                pendingTruncates: pendingTruncatesBinding,
                pendingDeletes: pendingDeletesBinding,
                tableOperationOptions: tableOperationOptionsBinding,
                databaseType: session.connection.type,
                connectionId: session.connection.id,
                coordinator: coordinator
            )
            .transaction { $0.animation = nil }
            .searchable(
                text: sidebarSearchBinding(sidebarState: sidebarState, coordinator: coordinator),
                placement: .sidebar,
                prompt: sidebarSearchPrompt(sidebarState: sidebarState)
            )
        } else {
            Color.clear
        }
    }

    private func sidebarSearchBinding(
        sidebarState: SharedSidebarState,
        coordinator: MainContentCoordinator
    ) -> Binding<String> {
        Binding(
            get: {
                switch sidebarState.selectedSidebarTab {
                case .tables: sidebarState.searchText
                case .favorites: coordinator.windowSidebarState.favoritesSearchText
                }
            },
            set: { newValue in
                switch sidebarState.selectedSidebarTab {
                case .tables:
                    sidebarState.searchText = newValue
                case .favorites:
                    coordinator.windowSidebarState.favoritesSearchText = newValue
                }
            }
        )
    }

    private func sidebarSearchPrompt(sidebarState: SharedSidebarState) -> String {
        switch sidebarState.selectedSidebarTab {
        case .tables: String(localized: "Filter")
        case .favorites: String(localized: "Filter favorites")
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let session = windowState.currentSession,
           let rightPanelState = windowState.rightPanelState,
           let sessionState = windowState.sessionState {
            MainContentView(
                connection: session.connection,
                payload: windowState.payload,
                windowTitle: windowTitleBinding,
                sidebarState: SharedSidebarState.forConnection(session.connection.id),
                pendingTruncates: pendingTruncatesBinding,
                pendingDeletes: pendingDeletesBinding,
                tableOperationOptions: tableOperationOptionsBinding,
                rightPanelState: rightPanelState,
                tabManager: sessionState.tabManager,
                changeManager: sessionState.changeManager,
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
    private var inspectorColumn: some View {
        if windowState.inspectorPresented,
           let session = windowState.currentSession,
           let rightPanelState = windowState.rightPanelState {
            UnifiedRightPanelView(
                state: rightPanelState,
                connection: session.connection,
                tables: session.tables
            )
        } else {
            Color.clear
        }
    }

    private func handleSidebarDoubleClick(table: TableInfo, coordinator: MainContentCoordinator) {
        let connectionId = coordinator.connectionId
        let isView = table.type == .view
        if let preview = WindowLifecycleMonitor.shared.previewWindow(for: connectionId),
           let previewCoordinator = MainContentCoordinator.coordinator(for: preview.windowId) {
            if previewCoordinator.tabManager.selectedTab?.tableContext.tableName == table.name {
                previewCoordinator.promotePreviewTab()
            } else {
                previewCoordinator.promotePreviewTab()
                coordinator.openTableTab(table.name, isView: isView)
            }
        } else {
            coordinator.promotePreviewTab()
            coordinator.openTableTab(table.name, isView: isView)
        }
    }

    // MARK: - Session Bindings

    private var pendingTruncatesBinding: Binding<Set<String>> {
        sessionBinding(get: { $0.pendingTruncates }, set: { $0.pendingTruncates = $1 }, defaultValue: [])
    }

    private var pendingDeletesBinding: Binding<Set<String>> {
        sessionBinding(get: { $0.pendingDeletes }, set: { $0.pendingDeletes = $1 }, defaultValue: [])
    }

    private var tableOperationOptionsBinding: Binding<[String: TableOperationOptions]> {
        sessionBinding(get: { $0.tableOperationOptions }, set: { $0.tableOperationOptions = $1 }, defaultValue: [:])
    }

    private var windowTitleBinding: Binding<String> {
        Binding(
            get: { windowState.windowTitle },
            set: { windowState.updateWindowTitle($0) }
        )
    }

    private func sessionBinding<T>(
        get: @escaping (ConnectionSession) -> T,
        set: @escaping (inout ConnectionSession, T) -> Void,
        defaultValue: T
    ) -> Binding<T> {
        Binding(
            get: {
                guard let session = windowState.currentSession else { return defaultValue }
                return get(session)
            },
            set: { newValue in
                guard let sessionId = windowState.payload?.connectionId
                    ?? windowState.currentSession?.id else { return }
                Task {
                    DatabaseManager.shared.updateSession(sessionId) { session in
                        set(&session, newValue)
                    }
                }
            }
        )
    }
}
