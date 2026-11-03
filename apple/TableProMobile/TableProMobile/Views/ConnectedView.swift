import SwiftUI
import TableProConnectionLibrary
import TableProDatabase
import TableProModels

struct ConnectedView: View {
    @Environment(AppState.self) private var appState
    @Environment(ConnectionCoordinatorStore.self) private var coordinatorStore
    @Environment(ScenePresenter.self) private var presenter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(SceneMenuState.self) private var menuState: SceneMenuState?
    let connection: DatabaseConnection

    @State private var coordinator: ConnectionCoordinator?
    @State private var menuOwner = UUID()
    @State private var hapticSuccess = false
    @State private var hapticError = false
    @State private var showDeletedAlert = false
    @State private var databaseSwitchAwaitingRollBack: String?
    @State private var retries = 0

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
                    .connectionPrompts(coordinator.prompts)
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
        // Retry runs here too, so closing the screen abandons it the way it abandons the first attempt.
        .task(id: ConnectRequest(generation: coordinatorStore.generation(for: connection.id), retries: retries)) {
            guard let record = liveRecord else { return }
            let resolved = coordinatorStore.coordinator(for: record, appState: appState)
            coordinator = resolved
            if let table = presenter.takeTable(for: connection.id) {
                resolved.pendingTableName = table
            }
            if case .connected = resolved.phase {
                resolved.navigateToPendingTable()
                // The session can die while the cover is closed, and nothing else pings it before a read fails.
                await resolved.reconnectIfNeeded()
                return
            }
            await resolved.connect()
            guard !Task.isCancelled else { return }
            switch resolved.phase {
            case .connected:
                resolved.loadHistory()
                hapticSuccess.toggle()
            case .failed, .lost:
                hapticError.toggle()
            case .notConnected, .connecting:
                break
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
        .onChange(of: appState.tunnelDeaths[connection.id]) {
            Task { await coordinator?.reconnectIfNeeded() }
        }
        .sensoryFeedback(.success, trigger: hapticSuccess)
        .sensoryFeedback(.error, trigger: hapticError)
    }

    @ViewBuilder
    private func screen(for coordinator: ConnectionCoordinator) -> some View {
        switch ConnectedScreen.resolve(
            phase: coordinator.phase,
            isReconnecting: coordinator.isReconnecting,
            isHeldByEditor: presenter.isHeldByEditor
        ) {
        case .connecting:
            statusScreen { connectingView }
        case .notConnected:
            statusScreen { notConnectedView }
        case .failed(let error):
            statusScreen { unavailableView(error, title: nil, systemImage: nil) }
        case .lost(let error):
            let presentation = ConnectionStatusPresentation(coordinator.displayStatus)
            statusScreen {
                unavailableView(error, title: presentation.title, systemImage: presentation.symbol?.systemName)
            }
        case .tabs:
            connectedContent(coordinator)
        }
    }

    private func unavailableView(_ error: AppError, title: String?, systemImage: String?) -> some View {
        ErrorView(
            error: error,
            title: title,
            systemImage: systemImage,
            retryTitle: String(localized: "Reconnect"),
            onRetry: error.canRetry ? { retries += 1 } : nil,
            onEditConnection: connection.isSample ? nil : { presenter.presentConnectionEditor(for: connection.id) }
        )
    }

    // A cancelled connect is neither a failure nor a lost session, so it offers Connect and no error.
    private var notConnectedView: some View {
        ContentUnavailableView {
            Text(String(localized: "Not Connected"))
        } actions: {
            Button(String(localized: "Connect")) { retries += 1 }
                .buttonStyle(.borderedProminent)
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
                coordinator?.cancelConnect()
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
                NavigationSplitView {
                    // Side by side, the detail column already shows the status and the bar.
                    tabChrome(coordinator, showsStatus: horizontalSizeClass == .compact) {
                        TableListView(connectionId: connection.id)
                    }
                    .transactionBar(for: coordinator, isEnabled: horizontalSizeClass == .compact)
                } detail: {
                    NavigationStack {
                        if let table = coordinator.selectedTable {
                            DataBrowserView(table: table)
                                .disabled(coordinator.isSwitching)
                                .environment(coordinator)
                                .connectionStatusToolbar(for: coordinator)
                                .transactionBar(for: coordinator)
                        } else {
                            ContentUnavailableView(
                                "No Table Selected",
                                systemImage: "tablecells",
                                description: Text("Pick a table to browse its rows.")
                            )
                            .connectionStatusToolbar(for: coordinator)
                            .transactionBar(for: coordinator)
                        }
                    }
                    .id(TableBrowserIdentity(coordinator.selectedTable, coordinator.activeDatabase))
                }
                .navigationSplitViewStyle(.balanced)
            }
            Tab("Query", systemImage: "terminal", value: .query) {
                NavigationStack {
                    tabChrome(coordinator) { QueryEditorView(connectionId: connection.id) }
                        .transactionBar(for: coordinator)
                }
            }
            Tab("History", systemImage: "clock", value: .history) {
                NavigationStack {
                    tabChrome(coordinator) { QueryHistoryView() }
                        .transactionBar(for: coordinator)
                }
            }
            Tab("Info", systemImage: "info.circle", value: .info) {
                NavigationStack {
                    tabChrome(coordinator) { ConnectionInfoView() }
                        .transactionBar(for: coordinator)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .transactionAccessory(for: coordinator)
        .onChange(of: appState.sessionTransactions.rollBackCount(for: connection.id)) {
            Task { await coordinator.reloadAfterRollBack() }
        }
        .onChange(of: appState.catalogChanges.generation(for: connection.id)) {
            Task { await coordinator.reloadChangedCatalog() }
        }
        // A reload that would have read a busy session waits for it.
        .onChange(of: appState.sessionTransactions.isBusy(connection.id)) { _, busy in
            guard !busy else { return }
            Task { await coordinator.reloadChangedCatalog() }
        }
        .onChange(of: appState.sessionRevision(for: connection.id)) {
            Task { await coordinator.followLiveSession() }
        }
        .onChange(of: presenter.isHeldByEditor, initial: true) { _, held in
            coordinator.isHeldByEditor = held
        }
        .onDisappear { coordinator.isHeldByEditor = false }
        // tabChrome sits inside each stack; this also reaches pushed row screens and their sheets, which track writes.
        .environment(coordinator)
        .onAppear {
            menuState?.publishTabs(ConnectedTabActions { coordinator.selectedTab = $0 }, from: menuOwner)
        }
        .onDisappear { menuState?.withdrawTabs(menuOwner) }
        .alert(
            coordinator.failureAlertTitle ?? String(localized: "Error"),
            isPresented: $coordinator.showFailureAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.failureAlertMessage ?? "")
        }
        .confirmationDialog(
            String(localized: "Switch Database?"),
            isPresented: Binding(
                get: { databaseSwitchAwaitingRollBack != nil },
                set: { if !$0 { databaseSwitchAwaitingRollBack = nil } }
            ),
            titleVisibility: .visible,
            presenting: databaseSwitchAwaitingRollBack
        ) { database in
            Button(String(localized: "Switch"), role: .destructive) {
                Task { await coordinator.switchDatabase(to: database) }
            }
        } message: { _ in
            Text(String(
                format: String(localized: "The database “%@” has an open transaction. Switching rolls it back and discards its uncommitted changes."),
                coordinator.activeDatabase
            ))
        }
        .userActivity(SceneIntent.viewConnectionActivity, isActive: appState.offersHandoff(for: connection)) { activity in
            activity.title = connection.name.isEmpty ? connection.host : connection.name
            activity.isEligibleForHandoff = true
            activity.userInfo = ["connectionId": connection.id.uuidString]
        }
    }

    // A switch blocks edits on the content only, so the tabs, Connections and the status stay usable.
    private func tabChrome(
        _ coordinator: ConnectionCoordinator,
        showsStatus: Bool = true,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        content()
            .disabled(coordinator.isSwitching)
            .environment(coordinator)
            .navigationTitle(displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeToolbar }
            .toolbar { connectionToolbar(coordinator) }
            .connectionStatusToolbar(for: coordinator, isEnabled: showsStatus)
    }

    // MARK: - Connection Toolbar

    @ToolbarContentBuilder
    private func connectionToolbar(_ coordinator: ConnectionCoordinator) -> some ToolbarContent {
        if coordinator.selectedTab == .info, !connection.isSample {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presenter.presentConnectionEditor(for: connection.id)
                } label: {
                    Label("Edit Connection", systemImage: "pencil")
                }
            }
        }
        if let badge = SafeModeBadge(level: connection.safeModeLevel) {
            ToolbarItem(placement: .topBarTrailing) {
                Label(badge.title, systemImage: badge.symbolName)
                    .foregroundStyle(badge.tint == .blocked ? Color.red : Color.orange)
            }
        }
        if coordinator.supportsDatabaseSwitching && coordinator.databases.count > 1 {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(coordinator.databases, id: \.self) { db in
                        Button {
                            requestDatabaseSwitch(to: db, on: coordinator)
                        } label: {
                            if db == coordinator.activeDatabase {
                                Label(db, systemImage: "checkmark")
                            } else {
                                Text(db)
                            }
                        }
                    }
                } label: {
                    Label(coordinator.activeDatabase, systemImage: "cylinder.split.1x2")
                        .font(.subheadline)
                }
                .disabled(coordinator.isSwitching || presenter.isHeldByEditor || coordinator.anotherWindowHoldsEditor)
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

    private func requestDatabaseSwitch(to database: String, on coordinator: ConnectionCoordinator) {
        if TransactionIndicatorContent.databaseSwitchEndsSession(for: coordinator.connection.type),
           coordinator.transactionHold != nil {
            databaseSwitchAwaitingRollBack = database
        } else {
            Task { await coordinator.switchDatabase(to: database) }
        }
    }
}

nonisolated private struct ConnectRequest: Equatable {
    let generation: Int
    let retries: Int
}
