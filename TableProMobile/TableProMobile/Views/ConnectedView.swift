import SwiftUI
import TableProDatabase
import TableProModels

struct ConnectedView: View {
    @Environment(AppState.self) private var appState
    @Environment(ConnectionCoordinatorStore.self) private var coordinatorStore
    @Environment(ScenePresenter.self) private var presenter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    let connection: DatabaseConnection

    @State private var coordinator: ConnectionCoordinator?
    @State private var hapticSuccess = false
    @State private var hapticError = false
    @State private var showDeletedAlert = false

    private var displayTitle: String {
        connection.name.isEmpty ? connection.host : connection.name
    }

    private var liveRecord: DatabaseConnection? {
        appState.connections.first { $0.id == connection.id }
    }

    private var isRemoved: Bool {
        appState.isConnectionRemoved(connection.id)
    }

    private var connectionEditorPresented: Binding<Bool> {
        Binding(
            get: { presenter.isEditingConnection(connection.id) },
            set: { if !$0 { presenter.dismissConnectionEditor() } }
        )
    }

    var body: some View {
        Group {
            if let coordinator {
                screen(for: coordinator)
            } else {
                statusScreen { connectingView }
            }
        }
        .onChange(of: isRemoved, initial: true) { _, removed in
            guard removed else { return }
            presenter.dismissConnectionEditor()
            showDeletedAlert = true
        }
        .alert(String(localized: "Connection Deleted"), isPresented: $showDeletedAlert) {
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            Text("This connection no longer exists. It may have been removed from another device.")
        }
        .sheet(isPresented: connectionEditorPresented) {
            ConnectionFormView(editing: liveRecord ?? connection) { _ in
                presenter.dismissConnectionEditor()
            }
        }
        .task(id: coordinatorStore.generation(for: connection.id)) {
            guard let record = liveRecord else { return }
            let resolved = coordinatorStore.coordinator(for: record, appState: appState)
            coordinator = resolved
            if let table = presenter.takeTable(for: connection.id) {
                resolved.pendingTableName = table
            }
            if case .connected = resolved.phase {
                resolved.navigateToPendingTable()
                return
            }
            await resolved.connect()
            guard !Task.isCancelled else { return }
            if case .connected = resolved.phase {
                resolved.loadHistory()
                hapticSuccess.toggle()
            } else if case .error = resolved.phase {
                hapticError.toggle()
            }
        }
        .onChange(of: presenter.pendingTable) { _, _ in
            guard let coordinator, let table = presenter.takeTable(for: connection.id) else { return }
            coordinator.pendingTableName = table
            coordinator.navigateToPendingTable()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await coordinator?.reconnectIfNeeded() }
            }
        }
        .sensoryFeedback(.success, trigger: hapticSuccess)
        .sensoryFeedback(.error, trigger: hapticError)
    }

    @ViewBuilder
    private func screen(for coordinator: ConnectionCoordinator) -> some View {
        switch ConnectedScreen.resolve(phase: coordinator.phase, isHeldByEditor: presenter.isHeldByEditor) {
        case .connecting:
            statusScreen { connectingView }
        case .failed(let error):
            statusScreen {
                ErrorView(error: error) {
                    await coordinator.connect()
                }
            }
        case .tabs:
            connectedContent(coordinator)
        }
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
            DiscardChangesButton(hasChanges: presenter.isHeldByEditor) {
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
                Text(String(
                    format: String(localized: "Connecting to %@..."),
                    connection.name.isEmpty ? connection.host : connection.name
                ))
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                coordinator?.cancelConnect()
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
        .userActivity(SceneIntent.viewConnectionActivity, isActive: appState.offersHandoff(for: connection)) { activity in
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
        if coordinator.selectedTab == .info, !connection.isSample {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presenter.presentConnectionEditor(for: connection.id)
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
