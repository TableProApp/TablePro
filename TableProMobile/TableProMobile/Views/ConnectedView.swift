import SwiftUI
import TableProDatabase
import TableProModels

struct ConnectedView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    let connection: DatabaseConnection
    let cachedCoordinator: ConnectionCoordinator?
    let onCoordinatorCreated: (ConnectionCoordinator) -> Void

    @State private var coordinator: ConnectionCoordinator?
    @State private var hapticSuccess = false
    @State private var hapticError = false
    @State private var showDeletedAlert = false

    private var displayTitle: String {
        connection.name.isEmpty ? connection.host : connection.name
    }

    var body: some View {
        Group {
            if let coordinator {
                switch coordinator.phase {
                case .connecting:
                    statusScreen { connectingView }
                case .error(let error):
                    statusScreen {
                        ErrorView(error: error) {
                            await coordinator.connect()
                        }
                    }
                case .connected:
                    connectedContent(coordinator)
                }
            } else {
                statusScreen { connectingView }
            }
        }
        .onChange(of: appState.connections) { _, newConnections in
            if !newConnections.contains(where: { $0.id == connection.id }) {
                showDeletedAlert = true
            }
        }
        .alert(String(localized: "Connection Deleted"), isPresented: $showDeletedAlert) {
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            Text("This connection no longer exists. It may have been removed from another device.")
        }
        .task {
            if let cached = cachedCoordinator {
                coordinator = cached
                if case .connected = cached.phase { return }
                await cached.connect()
            } else {
                let c = ConnectionCoordinator(connection: connection, appState: appState)
                coordinator = c
                onCoordinatorCreated(c)
                c.restorePersistedState()
                await c.connect()
            }
            if let c = coordinator, !Task.isCancelled {
                if case .connected = c.phase {
                    c.loadHistory()
                    hapticSuccess.toggle()
                } else if case .error = c.phase {
                    hapticError.toggle()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await coordinator?.reconnectIfNeeded() }
            }
        }
        .sensoryFeedback(.success, trigger: hapticSuccess)
        .sensoryFeedback(.error, trigger: hapticError)
    }

    // MARK: - Chrome

    private func statusScreen(@ViewBuilder _ content: () -> some View) -> some View {
        NavigationStack {
            content()
                .navigationTitle(displayTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { closeToolbar }
        }
    }

    @ToolbarContentBuilder
    private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Label("Connections", systemImage: "chevron.backward")
            }
            .accessibilityLabel(Text("Connections"))
        }
    }

    // MARK: - Connecting

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView {
                Text(String(format: String(localized: "Connecting to %@..."),
                             connection.name.isEmpty ? connection.host : connection.name))
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Connected Content

    private func connectedContent(_ coordinator: ConnectionCoordinator) -> some View {
        @Bindable var coordinator = coordinator
        return TabView(selection: $coordinator.selectedTab) {
            Tab("Tables", systemImage: "tablecells", value: .tables) {
                NavigationStack(path: $coordinator.tablesPath) {
                    tabChrome(coordinator) {
                        TableListView(connectionId: connection.id)
                    }
                    .navigationDestination(for: TableInfo.self) { table in
                        DataBrowserView(table: table)
                            .environment(coordinator)
                    }
                }
            }
            Tab("Query", systemImage: "terminal", value: .query) {
                NavigationStack {
                    tabChrome(coordinator) { QueryEditorView() }
                }
            }
            Tab("History", systemImage: "clock", value: .history) {
                NavigationStack {
                    tabChrome(coordinator) { QueryHistoryView() }
                }
            }
            Tab("Info", systemImage: "info.circle", value: .info) {
                NavigationStack {
                    tabChrome(coordinator) { ConnectionInfoView() }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .background {
            Button("") { coordinator.selectedTab = .tables }
                .keyboardShortcut("1", modifiers: .command)
                .accessibilityLabel(Text("Tables"))
                .hidden()
            Button("") { coordinator.selectedTab = .query }
                .keyboardShortcut("2", modifiers: .command)
                .accessibilityLabel(Text("Query"))
                .hidden()
            Button("") { coordinator.selectedTab = .history }
                .keyboardShortcut("3", modifiers: .command)
                .accessibilityLabel(Text("History"))
                .hidden()
            Button("") { coordinator.selectedTab = .info }
                .keyboardShortcut("4", modifiers: .command)
                .accessibilityLabel(Text("Info"))
                .hidden()
        }
        .overlay(alignment: .top) {
            if coordinator.isReconnecting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(String(localized: "Reconnecting..."))
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 4)
            }
        }
        .animation(.default, value: coordinator.isReconnecting)
        .allowsHitTesting(!coordinator.isSwitching)
        .overlay {
            if coordinator.isSwitching {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                }
                .transition(.opacity)
            }
        }
        .animation(.default, value: coordinator.isSwitching)
        .alert("Error", isPresented: $coordinator.showFailureAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.failureAlertMessage ?? "")
        }
        .userActivity("com.TablePro.viewConnection") { activity in
            activity.title = connection.name.isEmpty ? connection.host : connection.name
            activity.isEligibleForHandoff = true
            activity.userInfo = ["connectionId": connection.id.uuidString]
        }
    }

    private func tabChrome(
        _ coordinator: ConnectionCoordinator,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        content()
            .environment(coordinator)
            .navigationTitle(displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeToolbar }
            .toolbar { connectionToolbar(coordinator) }
    }

    // MARK: - Connection Toolbar

    @ToolbarContentBuilder
    private func connectionToolbar(_ coordinator: ConnectionCoordinator) -> some ToolbarContent {
        if coordinator.selectedTab == .info {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    coordinator.showingEditSheet = true
                } label: {
                    Image(systemName: "pencil")
                        .accessibilityLabel(Text("Edit Connection"))
                }
            }
        }
        if connection.safeModeLevel != .off {
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: connection.safeModeLevel == .readOnly ? "lock.fill" : "shield.fill")
                    .foregroundStyle(connection.safeModeLevel == .readOnly ? .red : .orange)
                    .font(.caption)
            }
        }
        if coordinator.supportsDatabaseSwitching && coordinator.databases.count > 1 {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(coordinator.databases, id: \.self) { db in
                        Button {
                            Task { await coordinator.switchDatabase(to: db) }
                        } label: {
                            if db == coordinator.activeDatabase {
                                Label(db, systemImage: "checkmark")
                            } else {
                                Text(db)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(coordinator.activeDatabase)
                            .font(.subheadline)
                        if coordinator.isSwitching {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(coordinator.isSwitching)
            }
        }
        if coordinator.supportsSchemas && coordinator.schemas.count > 1 {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(coordinator.schemas, id: \.self) { schema in
                        Button {
                            Task { await coordinator.switchSchema(to: schema) }
                        } label: {
                            if schema == coordinator.activeSchema {
                                Label(schema, systemImage: "checkmark")
                            } else {
                                Text(schema)
                            }
                        }
                    }
                } label: {
                    Label(coordinator.activeSchema, systemImage: "square.3.layers.3d")
                        .font(.subheadline)
                }
                .disabled(coordinator.isSwitching)
            }
        }
    }
}
