//
//  ConnectedView.swift
//  TableProMobile
//

import os
import SwiftUI
import TableProDatabase
import TableProModels

struct ConnectedView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    let connection: DatabaseConnection

    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectedView")

    @State private var session: ConnectionSession?
    @State private var tables: [TableInfo] = []
    @State private var isConnecting = true
    @State private var appError: AppError?
    @State private var failureAlertMessage: String?
    @State private var showFailureAlert = false
    @State private var selectedTab = ConnectedTab.tables
    @State private var queryHistory: [QueryHistoryItem] = []
    @State private var historyStorage = QueryHistoryStorage()
    @State private var databases: [String] = []
    @State private var activeDatabase: String = ""
    @State private var schemas: [String] = []
    @State private var activeSchema: String = "public"
    @State private var isSwitching = false
    @State private var isReconnecting = false
    @State private var hapticSuccess = false
    @State private var hapticError = false

    @Environment(\.dismiss) private var dismiss

    enum ConnectedTab: String, CaseIterable {
        case tables = "Tables"
        case query = "Query"
    }

    private var displayName: String {
        connection.name.isEmpty ? connection.host : connection.name
    }

    private var supportsDatabaseSwitching: Bool {
        connection.type == .mysql || connection.type == .mariadb ||
        connection.type == .postgresql || connection.type == .redshift
    }

    private var supportsSchemas: Bool {
        connection.type == .postgresql || connection.type == .redshift
    }

    var body: some View {
        Group {
            if isConnecting {
                VStack(spacing: 16) {
                    ProgressView {
                        Text(String(format: String(localized: "Connecting to %@..."), displayName))
                    }
                    Button(String(localized: "Cancel")) {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let appError {
                ErrorView(error: appError) {
                    await connect()
                }
            } else {
                connectedContent
                    .allowsHitTesting(!isSwitching)
                    .overlay {
                        if isSwitching {
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
                    .animation(.default, value: isSwitching)
            }
        }
        .sensoryFeedback(.success, trigger: hapticSuccess)
        .sensoryFeedback(.error, trigger: hapticError)
        .alert("Error", isPresented: $showFailureAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failureAlertMessage ?? "")
        }
        .navigationTitle(supportsDatabaseSwitching && databases.count > 1 ? "" : displayName)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            Picker("Tab", selection: $selectedTab) {
                Text("Tables").tag(ConnectedTab.tables)
                Text("Query").tag(ConnectedTab.query)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .toolbar {
            if connection.safeModeLevel != .off {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: connection.safeModeLevel == .readOnly ? "lock.fill" : "shield.fill")
                        .foregroundStyle(connection.safeModeLevel == .readOnly ? .red : .orange)
                        .font(.caption)
                }
            }
            if supportsDatabaseSwitching && databases.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(databases, id: \.self) { db in
                            Button {
                                Task { await switchDatabase(to: db) }
                            } label: {
                                if db == activeDatabase {
                                    Label(db, systemImage: "checkmark")
                                } else {
                                    Text(db)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(activeDatabase)
                                .font(.subheadline)
                            if isSwitching {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isSwitching)
                }
            }
            if supportsSchemas && schemas.count > 1 && selectedTab == .tables {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(schemas, id: \.self) { schema in
                            Button {
                                Task { await switchSchema(to: schema) }
                            } label: {
                                if schema == activeSchema {
                                    Label(schema, systemImage: "checkmark")
                                } else {
                                    Text(schema)
                                }
                            }
                        }
                    } label: {
                        Label(activeSchema, systemImage: "square.3.layers.3d")
                            .font(.subheadline)
                    }
                    .disabled(isSwitching)
                }
            }
        }
        .task {
            await connect()
            if !Task.isCancelled {
                queryHistory = historyStorage.load(for: connection.id)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, session != nil {
                Task { await reconnectIfNeeded() }
            }
        }
    }

    private var connectedContent: some View {
        VStack(spacing: 0) {
            switch selectedTab {
            case .tables:
                TableListView(
                    connection: connection,
                    tables: tables,
                    session: session,
                    onRefresh: { await refreshTables() }
                )
            case .query:
                QueryEditorView(
                    session: session,
                    tables: tables,
                    databaseType: connection.type,
                    safeModeLevel: connection.safeModeLevel,
                    queryHistory: $queryHistory,
                    connectionId: connection.id,
                    historyStorage: historyStorage
                )
            }
        }
    }

    private func connect() async {
        guard session == nil else {
            isConnecting = false
            return
        }

        isConnecting = true
        appError = nil

        // Reuse existing session if still alive in ConnectionManager
        if let existing = appState.connectionManager.session(for: connection.id) {
            self.session = existing
            do {
                self.tables = try await existing.driver.fetchTables(schema: nil)
                guard !Task.isCancelled else { return }
                await loadDatabases()
                await loadSchemas()
            } catch {
                // Session stale — disconnect and reconnect
                await appState.connectionManager.disconnect(connection.id)
                await connectFresh()
                return
            }
            isConnecting = false
            return
        }

        await connectFresh()
    }

    private func connectFresh() async {
        await appState.sshProvider.setPendingConnectionId(connection.id)

        do {
            let session = try await appState.connectionManager.connect(connection)
            guard !Task.isCancelled else {
                await appState.connectionManager.disconnect(connection.id)
                return
            }
            self.session = session
            self.tables = try await session.driver.fetchTables(schema: nil)
            isConnecting = false
            hapticSuccess.toggle()
            await loadDatabases()
            await loadSchemas()
        } catch {
            guard !Task.isCancelled else { return }
            let context = ErrorContext(
                operation: "connect",
                databaseType: connection.type,
                host: connection.host,
                sshEnabled: connection.sshEnabled
            )
            appError = ErrorClassifier.classify(error, context: context)
            isConnecting = false
            hapticError.toggle()
        }
    }

    private func reconnectIfNeeded() async {
        guard let session, !isSwitching, !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }
        do {
            _ = try await session.driver.ping()
        } catch {
            // Connection lost — reconnect
            do {
                await appState.sshProvider.setPendingConnectionId(connection.id)
                let newSession = try await appState.connectionManager.connect(connection)
                self.session = newSession
            } catch {
                let context = ErrorContext(
                    operation: "reconnect",
                    databaseType: connection.type,
                    host: connection.host,
                    sshEnabled: connection.sshEnabled
                )
                appError = ErrorClassifier.classify(error, context: context)
                self.session = nil
            }
        }
    }

    private func loadDatabases() async {
        guard let session, supportsDatabaseSwitching else { return }
        do {
            databases = try await session.driver.fetchDatabases()
            // Use session's active database (may differ from connection.database after a switch)
            if let stored = appState.connectionManager.session(for: connection.id) {
                activeDatabase = stored.activeDatabase
            } else {
                activeDatabase = connection.database
            }
        } catch {
            // Silently fail — just don't show picker
        }
    }

    private func loadSchemas() async {
        guard let session, supportsSchemas else { return }
        do {
            schemas = try await session.driver.fetchSchemas()
            activeSchema = session.driver.currentSchema ?? "public"
        } catch {
            // Silently fail — don't show picker
        }
    }

    private func switchSchema(to name: String) async {
        guard let session, name != activeSchema, !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }

        do {
            try await session.driver.switchSchema(to: name)
            activeSchema = name
            self.tables = try await session.driver.fetchTables(schema: name)
        } catch {
            failureAlertMessage = String(localized: "Failed to switch schema")
            showFailureAlert = true
        }
    }

    private func switchDatabase(to name: String) async {
        guard let session, name != activeDatabase, !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }

        if connection.type == .postgresql || connection.type == .redshift {
            await reconnectWithDatabase(name)
        } else {
            do {
                try await appState.connectionManager.switchDatabase(connection.id, to: name)
                activeDatabase = name
                self.tables = try await session.driver.fetchTables(schema: nil)
            } catch {
                failureAlertMessage = String(localized: "Failed to switch database")
                showFailureAlert = true
            }
        }
    }

    private func reconnectWithDatabase(_ database: String) async {
        await appState.connectionManager.disconnect(connection.id)
        self.session = nil

        var newConnection = connection
        newConnection.database = database

        await appState.sshProvider.setPendingConnectionId(connection.id)

        do {
            let newSession = try await appState.connectionManager.connect(newConnection)
            self.session = newSession
            self.tables = try await newSession.driver.fetchTables(schema: nil)
            activeDatabase = database
            await loadSchemas()
        } catch {
            // Reconnect to original database as fallback
            Self.logger.error("Failed to switch to database \(database, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await appState.sshProvider.setPendingConnectionId(connection.id)
            do {
                let fallbackSession = try await appState.connectionManager.connect(connection)
                self.session = fallbackSession
                self.tables = try await fallbackSession.driver.fetchTables(schema: nil)
                failureAlertMessage = String(localized: "Failed to switch database")
                showFailureAlert = true
            } catch {
                // Both failed — show error view
                let context = ErrorContext(
                    operation: "switchDatabase",
                    databaseType: connection.type,
                    host: connection.host,
                    sshEnabled: connection.sshEnabled
                )
                appError = ErrorClassifier.classify(error, context: context)
                self.session = nil
            }
        }
    }

    private func refreshTables() async {
        guard let session else { return }
        do {
            let schema = supportsSchemas ? activeSchema : nil
            self.tables = try await session.driver.fetchTables(schema: schema)
        } catch {
            Self.logger.warning("Failed to refresh tables: \(error.localizedDescription, privacy: .public)")
            failureAlertMessage = String(localized: "Failed to refresh tables")
            showFailureAlert = true
        }
    }
}
