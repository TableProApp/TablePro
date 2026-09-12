import Foundation
import Observation
import os
import SwiftUI
import TableProDatabase
import TableProModels

@MainActor @Observable
final class ConnectionCoordinator {
    let connection: DatabaseConnection

    private(set) var session: ConnectionSession?
    private(set) var phase: ConnectionPhase = .connecting
    private(set) var tables: [TableInfo] = []
    private(set) var databases: [String] = []
    private(set) var schemas: [String] = []
    private(set) var activeDatabase: String = ""
    private(set) var activeSchema: String = "public"

    private(set) var isSwitching = false
    private(set) var isReconnecting = false
    var failureAlertMessage: String?
    var showFailureAlert = false

    var selectedTab: ConnectedTab = .tables {
        didSet {
            UserDefaults.standard.set(selectedTab.rawValue, forKey: "lastTab.\(connection.id.uuidString)")
        }
    }
    var pendingQuery: String?
    var tablesPath = NavigationPath()
    var showingEditSheet = false

    private(set) var queryHistory: [QueryHistoryItem] = []
    private let historyStorage = QueryHistoryStorage()

    private let appState: AppState

    var connectionManager: ConnectionManager { appState.connectionManager }
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionCoordinator")

    enum ConnectionPhase: Sendable {
        case connecting
        case connected
        case error(AppError)
    }

    var displayName: String {
        connection.name.isEmpty ? connection.host : connection.name
    }

    var supportsDatabaseSwitching: Bool {
        connection.type == .mysql || connection.type == .mariadb ||
        connection.type == .tidb || connection.type == .oceanbase ||
        connection.type == .postgresql || connection.type == .redshift ||
        connection.type == .mssql
    }

    var supportsSchemas: Bool {
        connection.type == .postgresql || connection.type == .redshift ||
        connection.type == .mssql || connection.type == .duckdb ||
        connection.type == .oracle
    }

    init(connection: DatabaseConnection, appState: AppState) {
        self.connection = connection
        self.appState = appState
    }

    // MARK: - Persisted State

    func restorePersistedState() {
        let key = connection.id.uuidString
        if let savedTab = UserDefaults.standard.string(forKey: "lastTab.\(key)"),
           let tab = ConnectedTab(rawValue: savedTab) {
            selectedTab = tab
        }
        activeDatabase = UserDefaults.standard.string(forKey: "lastDB.\(key)") ?? ""
        activeSchema = UserDefaults.standard.string(forKey: "lastSchema.\(key)") ?? "public"
    }

    // MARK: - Connection Lifecycle

    /// The attempt allowed to write `session` and `phase`. Cancelling mints a new one.
    private var attemptToken = UUID()
    private var connectTask: Task<Void, Never>?

    var isConnecting: Bool { connectTask != nil }

    /// Returning early without touching `phase` is what left the connecting screen up for good.
    func connect() async {
        if let inFlight = connectTask {
            await inFlight.value
            return
        }

        let token = UUID()
        attemptToken = token
        phase = .connecting

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAttempt(token: token)
        }
        connectTask = task
        await task.value
        if connectTask == task { connectTask = nil }
    }

    /// Never waits on the driver: `Task.cancel()` is cooperative and these drivers ignore it.
    func cancelConnect() {
        guard connectTask != nil else { return }
        attemptToken = UUID()
        connectTask?.cancel()
        connectTask = nil
        appState.connectionManager.invalidateAttempt(for: connection.id)
        session = nil
        phase = .error(Self.cancelledError)
    }

    private static var cancelledError: AppError {
        AppError(
            category: .network,
            title: String(localized: "Connection Cancelled"),
            message: String(localized: "The connection attempt was cancelled."),
            recovery: String(localized: "Tap Retry to try again."),
            underlying: nil
        )
    }

    private func runAttempt(token: UUID) async {
        if let existing = appState.connectionManager.session(for: connection.id) {
            do {
                let existingTables = try await existing.driver.fetchTables(schema: nil)
                guard attemptToken == token else { return }
                session = existing
                tables = existingTables
                await loadDatabases()
                await loadSchemas()
                guard attemptToken == token else { return }
                phase = .connected
                return
            } catch {
                guard attemptToken == token else { return }
                session = nil
                await appState.connectionManager.disconnect(connection.id)
            }
        }

        guard attemptToken == token else { return }
        await connectFresh(token: token)
    }

    /// `allowSignIn` is false on the retry that follows a sign-in, so a connection that keeps
    /// failing cannot put the prompt up again and again.
    private func connectFresh(token: UUID, allowSignIn: Bool = true) async {
        IOSAnalyticsProvider.shared.markConnectionAttempted()

        do {
            let newSession = try await appState.connectionManager.connect(connection)
            let newTables = try await newSession.driver.fetchTables(schema: nil)
            guard attemptToken == token else { return }
            session = newSession
            tables = newTables
            await loadDatabases()
            await loadSchemas()
            guard attemptToken == token else { return }
            phase = .connected
            IOSAnalyticsProvider.shared.markConnectionSucceeded()
            navigateToPendingTable()
        } catch {
            guard attemptToken == token else { return }
            // A sign-in that expired is recoverable, so offer it once and retry rather than
            // leaving the user on an error screen whose only button repeats the same failure.
            if allowSignIn,
               EntraSignIn.needsSignIn(error),
               await EntraSignIn.offer(fields: connection.additionalFields) {
                guard attemptToken == token else { return }
                await connectFresh(token: token, allowSignIn: false)
                return
            }
            guard attemptToken == token else { return }
            let context = ErrorContext(
                operation: "connect",
                databaseType: connection.type,
                host: connection.host,
                sshEnabled: connection.sshEnabled
            )
            phase = .error(ErrorClassifier.classify(error, context: context))
        }
    }

    func reconnectIfNeeded() async {
        guard let session, !isSwitching, !isReconnecting, connectTask == nil else { return }
        do {
            _ = try await session.driver.ping()
            return
        } catch {
            // Ping failed; fall through to actual reconnect path below.
        }

        let token = attemptToken
        isReconnecting = true
        defer { isReconnecting = false }
        do {
            let newSession = try await appState.connectionManager.connect(connection)
            guard attemptToken == token else { return }
            self.session = newSession
        } catch {
            guard attemptToken == token else { return }
            let context = ErrorContext(
                operation: "reconnect",
                databaseType: connection.type,
                host: connection.host,
                sshEnabled: connection.sshEnabled
            )
            phase = .error(ErrorClassifier.classify(error, context: context))
            self.session = nil
        }
    }

    // MARK: - Database / Schema Switching

    func switchDatabase(to name: String) async {
        guard session != nil, name != activeDatabase, !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }

        if connection.type == .postgresql || connection.type == .redshift {
            await reconnectWithDatabase(name)
        } else {
            do {
                try await appState.connectionManager.switchDatabase(connection.id, to: name)
                if let freshSession = appState.connectionManager.session(for: connection.id) {
                    self.session = freshSession
                }
                activeDatabase = name
                UserDefaults.standard.set(name, forKey: "lastDB.\(connection.id.uuidString)")
                if let current = self.session {
                    self.tables = try await current.driver.fetchTables(schema: nil)
                }
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

        let token = attemptToken
        do {
            let newSession = try await appState.connectionManager.connect(newConnection)
            guard attemptToken == token else { return }
            self.session = newSession
            self.tables = try await newSession.driver.fetchTables(schema: nil)
            activeDatabase = database
            UserDefaults.standard.set(database, forKey: "lastDB.\(connection.id.uuidString)")
            await loadSchemas()
        } catch {
            Self.logger.error("Failed to switch to database \(database, privacy: .public): \(error.localizedDescription, privacy: .public)")
            do {
                let fallbackSession = try await appState.connectionManager.connect(connection)
                guard attemptToken == token else { return }
                self.session = fallbackSession
                self.tables = try await fallbackSession.driver.fetchTables(schema: nil)
                failureAlertMessage = String(localized: "Failed to switch database")
                showFailureAlert = true
            } catch {
                let context = ErrorContext(
                    operation: "switchDatabase",
                    databaseType: connection.type,
                    host: connection.host,
                    sshEnabled: connection.sshEnabled
                )
                phase = .error(ErrorClassifier.classify(error, context: context))
                self.session = nil
            }
        }
    }

    func switchSchema(to name: String) async {
        guard let session, name != activeSchema, !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }

        do {
            try await session.driver.switchSchema(to: name)
            activeSchema = name
            UserDefaults.standard.set(name, forKey: "lastSchema.\(connection.id.uuidString)")
            self.tables = try await session.driver.fetchTables(schema: name)
        } catch {
            failureAlertMessage = String(localized: "Failed to switch schema")
            showFailureAlert = true
        }
    }

    // MARK: - Tables

    func refreshTables() async {
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

    // MARK: - Query History

    func loadHistory() {
        queryHistory = historyStorage.load(for: connection.id)
    }

    func addHistoryItem(_ item: QueryHistoryItem) {
        historyStorage.save(item)
        queryHistory.append(item)
    }

    func deleteHistoryItem(_ id: UUID) {
        historyStorage.delete(id)
        queryHistory.removeAll { $0.id == id }
    }

    func clearHistory() {
        historyStorage.clearAll(for: connection.id)
        queryHistory = []
    }

    func navigateToPendingTable() {
        guard let tableName = appState.pendingTableName,
              let table = tables.first(where: { $0.name == tableName }) else { return }
        appState.pendingTableName = nil
        selectedTab = .tables
        Task { @MainActor in
            tablesPath.append(table)
        }
    }

    // MARK: - Private Helpers

    private func loadDatabases() async {
        guard let session, supportsDatabaseSwitching else { return }
        do {
            databases = try await session.driver.fetchDatabases()
            if !activeDatabase.isEmpty, databases.contains(activeDatabase) {
                let sessionDB = appState.connectionManager.session(for: connection.id)?.activeDatabase ?? connection.database
                if activeDatabase != sessionDB {
                    let target = activeDatabase
                    activeDatabase = sessionDB
                    await switchDatabase(to: target)
                }
            } else if let stored = appState.connectionManager.session(for: connection.id) {
                activeDatabase = stored.activeDatabase
            } else {
                activeDatabase = connection.database
            }
        } catch {
            Self.logger.warning("Failed to load databases: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadSchemas() async {
        guard let session, supportsSchemas else { return }
        do {
            schemas = try await session.driver.fetchSchemas()
            let currentSchema = session.driver.currentSchema ?? "public"
            if schemas.contains(activeSchema), activeSchema != currentSchema {
                let target = activeSchema
                activeSchema = currentSchema
                await switchSchema(to: target)
            } else if !schemas.contains(activeSchema) {
                activeSchema = currentSchema
            }
        } catch {
            Self.logger.warning("Failed to load schemas: \(error.localizedDescription, privacy: .public)")
        }
    }
}
