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
        connection.type == .postgresql || connection.type == .redshift
    }

    var supportsSchemas: Bool {
        connection.type == .postgresql || connection.type == .redshift
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

    private var isConnecting = false

    func connect() async {
        guard !isConnecting, session == nil else {
            if session != nil { phase = .connected }
            return
        }

        isConnecting = true
        defer { isConnecting = false }
        phase = .connecting

        if let existing = appState.connectionManager.session(for: connection.id) {
            self.session = existing
            do {
                self.tables = try await existing.driver.fetchTables(schema: nil)
                await loadDatabases()
                await loadSchemas()
                phase = .connected
            } catch {
                self.session = nil
                await appState.connectionManager.disconnect(connection.id)
                await connectFresh()
            }
            return
        }

        await connectFresh()
    }

    private func connectFresh() async {
        await appState.sshProvider.setPendingConnectionId(connection.id)

        IOSAnalyticsProvider.shared.markConnectionAttempted()

        do {
            let newSession = try await appState.connectionManager.connect(connection)
            self.session = newSession
            self.tables = try await newSession.driver.fetchTables(schema: nil)
            await loadDatabases()
            await loadSchemas()
            phase = .connected
            IOSAnalyticsProvider.shared.markConnectionSucceeded()
            navigateToPendingTable()
        } catch {
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
        guard let session, !isSwitching, !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }
        do {
            _ = try await session.driver.ping()
        } catch {
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
                phase = .error(ErrorClassifier.classify(error, context: context))
                self.session = nil
            }
        }
    }

    // MARK: - Database / Schema Switching

    func switchDatabase(to name: String) async {
        guard let session, name != activeDatabase, !isSwitching else { return }
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

        await appState.sshProvider.setPendingConnectionId(connection.id)

        do {
            let newSession = try await appState.connectionManager.connect(newConnection)
            self.session = newSession
            self.tables = try await newSession.driver.fetchTables(schema: nil)
            activeDatabase = database
            UserDefaults.standard.set(database, forKey: "lastDB.\(connection.id.uuidString)")
            await loadSchemas()
        } catch {
            Self.logger.error("Failed to switch to database \(database, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await appState.sshProvider.setPendingConnectionId(connection.id)
            do {
                let fallbackSession = try await appState.connectionManager.connect(connection)
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
