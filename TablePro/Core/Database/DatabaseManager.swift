//
//  DatabaseManager.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import AppKit
import Foundation
import Observation
import os
import TableProPluginKit

/// Manages database connections and active drivers
@MainActor @Observable
final class DatabaseManager {
    static let shared = DatabaseManager()
    private static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseManager")

    /// All active connection sessions
    private(set) var activeSessions: [UUID: ConnectionSession] = [:] {
        didSet {
            if Set(oldValue.keys) != Set(activeSessions.keys) {
                connectionListVersion &+= 1
            }
            connectionStatusVersion &+= 1
        }
    }

    /// Incremented only when sessions are added or removed (keys change).
    private(set) var connectionListVersion: Int = 0

    /// Incremented when any session state changes (status, driver, metadata, etc.).
    private(set) var connectionStatusVersion: Int = 0

    /// Per-connection version counters. Views observe their specific connection's
    /// counter to avoid cross-connection re-renders.
    private(set) var connectionStatusVersions: [UUID: Int] = [:]

    /// Backward-compatible alias for views not yet migrated to fine-grained counters.
    var sessionVersion: Int { connectionStatusVersion }

    /// Currently selected session ID (displayed in UI)
    private(set) var currentSessionId: UUID?

    /// Health monitors for active connections (MySQL/PostgreSQL only)
    @ObservationIgnored private var healthMonitors: [UUID: ConnectionHealthMonitor] = [:]

    /// Tracks connections with user queries currently in-flight.
    /// The health monitor skips pings while a query is running to avoid
    /// racing on non-thread-safe driver connections.
    @ObservationIgnored private var queriesInFlight: [UUID: Int] = [:]
    /// Tracks when the first query started for each session (used for staleness detection).
    @ObservationIgnored private var queryStartTimes: [UUID: Date] = [:]

    /// Current session (computed from currentSessionId)
    var currentSession: ConnectionSession? {
        guard let sessionId = currentSessionId else { return nil }
        return activeSessions[sessionId]
    }

    /// Current driver (for convenience)
    var activeDriver: DatabaseDriver? {
        currentSession?.driver
    }

    /// Resolve the driver for a specific connection (session-scoped, no global state)
    func driver(for connectionId: UUID) -> DatabaseDriver? {
        activeSessions[connectionId]?.driver
    }

    /// Resolve a session by explicit connection ID
    func session(for connectionId: UUID) -> ConnectionSession? {
        activeSessions[connectionId]
    }

    /// Current connection status
    var status: ConnectionStatus {
        currentSession?.status ?? .disconnected
    }

    private init() {}

    // MARK: - Session Management

    /// Connect to a database and create/switch to its session
    /// If connection already has a session, switches to it instead
    func connectToSession(_ connection: DatabaseConnection) async throws {
        // Check if session already exists and is connected
        if let existing = activeSessions[connection.id], existing.driver != nil {
            // Session is fully connected, just switch to it
            switchToSession(connection.id)
            return
        }

        // Resolve environment variable references in connection fields (Pro feature)
        let resolvedConnection: DatabaseConnection
        if LicenseManager.shared.isFeatureAvailable(.envVarReferences) {
            resolvedConnection = EnvVarResolver.resolveConnection(connection)
        } else {
            resolvedConnection = connection
        }

        // Create new session (or reuse a prepared one)
        if activeSessions[connection.id] == nil {
            var session = ConnectionSession(connection: connection)
            session.status = .connecting
            setSession(session, for: connection.id)
        }
        currentSessionId = connection.id

        // Create SSH tunnel if needed and build effective connection
        let effectiveConnection: DatabaseConnection
        do {
            effectiveConnection = try await buildEffectiveConnection(for: resolvedConnection)
        } catch {
            // Remove failed session
            removeSessionEntry(for: connection.id)
            currentSessionId = nil
            throw error
        }

        // Run pre-connect hook if configured (only on explicit connect, not auto-reconnect)
        if let script = resolvedConnection.preConnectScript,
           !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            do {
                try await PreConnectHookRunner.run(script: script)
            } catch {
                removeSessionEntry(for: connection.id)
                currentSessionId = nil
                throw error
            }
        }

        // Resolve password override for prompt-for-password connections
        var passwordOverride: String?
        if connection.promptForPassword {
            if let cached = activeSessions[connection.id]?.cachedPassword {
                passwordOverride = cached
            } else {
                let isApiOnly = PluginManager.shared.connectionMode(for: connection.type) == .apiOnly
                guard let prompted = PasswordPromptHelper.prompt(
                    connectionName: connection.name,
                    isAPIToken: isApiOnly
                ) else {
                    removeSessionEntry(for: connection.id)
                    currentSessionId = nil
                    throw CancellationError()
                }
                passwordOverride = prompted
            }
        }

        // Create appropriate driver with effective connection
        let driver: DatabaseDriver
        do {
            driver = try DatabaseDriverFactory.createDriver(
                for: effectiveConnection,
                passwordOverride: passwordOverride
            )
        } catch {
            // Close tunnel if SSH was established
            if connection.sshConfig.enabled {
                Task {
                    do {
                        try await SSHTunnelManager.shared.closeTunnel(connectionId: connection.id)
                    } catch {
                        Self.logger.warning("SSH tunnel cleanup failed for \(connection.name): \(error.localizedDescription)")
                    }
                }
            }
            removeSessionEntry(for: connection.id)
            currentSessionId = nil
            throw error
        }

        do {
            try await driver.connect()

            // Apply query timeout from settings
            let timeoutSeconds = AppSettingsManager.shared.general.queryTimeoutSeconds
            if timeoutSeconds > 0 {
                try await driver.applyQueryTimeout(timeoutSeconds)
            }

            // Run startup commands before schema init
            await executeStartupCommands(
                resolvedConnection.startupCommands, on: driver, connectionName: connection.name
            )

            // Initialize schema for drivers that support schema switching
            if let schemaDriver = driver as? SchemaSwitchable {
                activeSessions[connection.id]?.currentSchema = schemaDriver.currentSchema
            }

            // Run post-connect actions declared by the plugin
            let postConnectActions = PluginMetadataRegistry.shared.snapshot(
                forTypeId: connection.type.pluginTypeId
            )?.postConnectActions ?? []

            for action in postConnectActions {
                switch action {
                case .selectDatabaseFromLastSession:
                    // Restore saved database (e.g. MSSQL) only when no explicit database is configured
                    if resolvedConnection.database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let adapter = driver as? PluginDriverAdapter,
                       let savedDb = AppSettingsStorage.shared.loadLastDatabase(for: connection.id) {
                        do {
                            try await adapter.switchDatabase(to: savedDb)
                            activeSessions[connection.id]?.currentDatabase = savedDb
                        } catch {
                            Self.logger.warning("Failed to restore saved database '\(savedDb, privacy: .public)' for \(connection.id): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                case .selectDatabaseFromConnectionField(let fieldId):
                    // Select database from a connection field (e.g. Redis database index).
                    // Check additionalFields first, then legacy dedicated properties, then
                    // fall back to parsing the main database field.
                    let initialDb: Int
                    if let fieldValue = resolvedConnection.additionalFields[fieldId], let parsed = Int(fieldValue) {
                        initialDb = parsed
                    } else if fieldId == "redisDatabase", let legacy = resolvedConnection.redisDatabase {
                        initialDb = legacy
                    } else if let fallback = Int(resolvedConnection.database) {
                        initialDb = fallback
                    } else {
                        initialDb = 0
                    }
                    if initialDb != 0 {
                        try? await (driver as? PluginDriverAdapter)?.switchDatabase(to: String(initialDb))
                    }
                    activeSessions[connection.id]?.currentDatabase = String(initialDb)
                }
            }

            // Batch all session mutations into a single write to fire objectWillChange once
            if var session = activeSessions[connection.id] {
                session.driver = driver
                session.status = driver.status
                session.effectiveConnection = effectiveConnection
                if let passwordOverride {
                    session.cachedPassword = passwordOverride
                }
                setSession(session, for: connection.id)
            }

            // Save as last connection for "Reopen Last Session" feature
            AppSettingsStorage.shared.saveLastConnectionId(connection.id)

            // Post notification for reliable delivery
            NotificationCenter.default.post(name: .databaseDidConnect, object: nil)

            // Start health monitoring if the plugin supports it
            let supportsHealth = PluginMetadataRegistry.shared.snapshot(
                forTypeId: connection.type.pluginTypeId
            )?.supportsHealthMonitor ?? true

            if supportsHealth {
                await startHealthMonitor(for: connection.id)
            }
        } catch {
            // Close tunnel if connection failed
            if connection.sshConfig.enabled {
                Task {
                    do {
                        try await SSHTunnelManager.shared.closeTunnel(connectionId: connection.id)
                    } catch {
                        Self.logger.warning("SSH tunnel cleanup failed for \(connection.name): \(error.localizedDescription)")
                    }
                }
            }

            // Remove failed session completely so UI returns to Welcome window
            removeSessionEntry(for: connection.id)

            // Clear current session if this was it
            if currentSessionId == connection.id {
                // Switch to another session if available, otherwise clear
                if let nextSessionId = activeSessions.keys.first {
                    currentSessionId = nextSessionId
                } else {
                    currentSessionId = nil
                }
            }

            throw error
        }
    }

    /// Switch to an existing session
    func switchToSession(_ sessionId: UUID) {
        guard activeSessions[sessionId] != nil else { return }
        currentSessionId = sessionId
        updateSession(sessionId) { session in
            session.markActive()
        }
    }

    /// Disconnect a specific session
    func disconnectSession(_ sessionId: UUID) async {
        guard let session = activeSessions[sessionId] else { return }

        // Close SSH tunnel if exists
        if session.connection.sshConfig.enabled {
            do {
                try await SSHTunnelManager.shared.closeTunnel(connectionId: session.connection.id)
            } catch {
                Self.logger.warning("SSH tunnel cleanup failed for \(session.connection.name): \(error.localizedDescription)")
            }
        }

        // Stop health monitoring
        await stopHealthMonitor(for: sessionId)

        session.driver?.disconnect()
        removeSessionEntry(for: sessionId)

        // Clean up shared schema cache for this connection
        SchemaProviderRegistry.shared.clear(for: sessionId)

        // Clean up shared sidebar state for this connection
        SharedSidebarState.removeConnection(sessionId)

        // If this was the current session, switch to another or clear
        if currentSessionId == sessionId {
            if let nextSessionId = activeSessions.keys.first {
                switchToSession(nextSessionId)
            } else {
                // No more sessions - clear current session and last connection ID
                currentSessionId = nil
                AppSettingsStorage.shared.saveLastConnectionId(nil)
            }
        }
    }

    /// Disconnect all sessions
    func disconnectAll() async {
        let monitorIds = Array(healthMonitors.keys)
        for sessionId in monitorIds {
            await stopHealthMonitor(for: sessionId)
        }

        let sessionIds = Array(activeSessions.keys)
        for sessionId in sessionIds {
            await disconnectSession(sessionId)
        }
    }

    /// Update session state (for preserving UI state).
    /// Skips the write-back when no observable fields changed, avoiding spurious connectionStatusVersion bumps.
    func updateSession(_ sessionId: UUID, update: (inout ConnectionSession) -> Void) {
        guard var session = activeSessions[sessionId] else { return }
        let before = session
        let driverBefore = session.driver as AnyObject?
        update(&session)
        let driverAfter = session.driver as AnyObject?
        guard !session.isContentViewEquivalent(to: before) || driverBefore !== driverAfter else { return }
        setSession(session, for: sessionId)
    }

    /// Write a session and bump its per-connection version counter.
    private func setSession(_ session: ConnectionSession, for connectionId: UUID) {
        activeSessions[connectionId] = session
        connectionStatusVersions[connectionId, default: 0] &+= 1
        NotificationCenter.default.post(name: .connectionStatusDidChange, object: connectionId)
    }

    /// Remove a session and clean up its per-connection version counter.
    private func removeSessionEntry(for connectionId: UUID) {
        activeSessions.removeValue(forKey: connectionId)
        connectionStatusVersions.removeValue(forKey: connectionId)
        NotificationCenter.default.post(name: .connectionStatusDidChange, object: connectionId)
    }

    #if DEBUG
    /// Test-only: inject a session for unit testing without real database connections
    internal func injectSession(_ session: ConnectionSession, for connectionId: UUID) {
        setSession(session, for: connectionId)
    }

    /// Test-only: remove an injected session
    internal func removeSession(for connectionId: UUID) {
        removeSessionEntry(for: connectionId)
    }
    #endif

    // MARK: - Query Execution (uses current session)

    /// Track an in-flight operation for the given session, preventing health monitor
    /// pings from racing on the same non-thread-safe driver connection.
    private func trackOperation<T>(
        sessionId: UUID,
        operation: () async throws -> T
    ) async throws -> T {
        queriesInFlight[sessionId, default: 0] += 1
        if queriesInFlight[sessionId] == 1 {
            queryStartTimes[sessionId] = Date()
        }
        defer {
            if let count = queriesInFlight[sessionId], count > 1 {
                queriesInFlight[sessionId] = count - 1
            } else {
                queriesInFlight.removeValue(forKey: sessionId)
                queryStartTimes.removeValue(forKey: sessionId)
            }
        }
        return try await operation()
    }

    /// Execute a query on the current session
    func execute(query: String) async throws -> QueryResult {
        guard let sessionId = currentSessionId, let driver = activeDriver else {
            throw DatabaseError.notConnected
        }

        return try await trackOperation(sessionId: sessionId) {
            try await driver.execute(query: query)
        }
    }

    /// Fetch tables from the current session
    func fetchTables() async throws -> [TableInfo] {
        guard let sessionId = currentSessionId, let driver = activeDriver else {
            throw DatabaseError.notConnected
        }

        return try await trackOperation(sessionId: sessionId) {
            try await driver.fetchTables()
        }
    }

    /// Fetch columns for a table from the current session
    func fetchColumns(table: String) async throws -> [ColumnInfo] {
        guard let sessionId = currentSessionId, let driver = activeDriver else {
            throw DatabaseError.notConnected
        }

        return try await trackOperation(sessionId: sessionId) {
            try await driver.fetchColumns(table: table)
        }
    }

    /// Test a connection without keeping it open
    func testConnection(
        _ connection: DatabaseConnection,
        sshPassword: String? = nil,
        passwordOverride: String? = nil
    ) async throws -> Bool {
        // Build effective connection (creates SSH tunnel if needed)
        let testConnection = try await buildEffectiveConnection(
            for: connection,
            sshPasswordOverride: sshPassword
        )

        let result: Bool
        do {
            let driver = try DatabaseDriverFactory.createDriver(
                for: testConnection,
                passwordOverride: passwordOverride
            )
            result = try await driver.testConnection()
        } catch {
            if connection.sshConfig.enabled {
                do {
                    try await SSHTunnelManager.shared.closeTunnel(connectionId: connection.id)
                } catch {
                    Self.logger.warning("SSH tunnel cleanup failed for \(connection.name): \(error.localizedDescription)")
                }
            }
            throw error
        }

        if connection.sshConfig.enabled {
            do {
                try await SSHTunnelManager.shared.closeTunnel(connectionId: connection.id)
            } catch {
                Self.logger.warning("SSH tunnel cleanup failed for \(connection.name): \(error.localizedDescription)")
            }
        }

        return result
    }

    // MARK: - SSH Tunnel Helper

    /// Build an effective connection for the given database connection.
    /// If SSH tunneling is enabled, creates a tunnel and returns a modified connection
    /// pointing at localhost with the tunnel port. Otherwise returns the original connection.
    ///
    /// - Parameters:
    ///   - connection: The original database connection configuration.
    ///   - sshPasswordOverride: Optional SSH password to use instead of the stored one (for test connections).
    /// - Returns: A connection suitable for the database driver (SSH disabled, pointing at tunnel if applicable).
    private func buildEffectiveConnection(
        for connection: DatabaseConnection,
        sshPasswordOverride: String? = nil
    ) async throws -> DatabaseConnection {
        // Resolve SSH configuration: profile takes priority over inline
        let profile = connection.sshProfileId.flatMap { SSHProfileStorage.shared.profile(for: $0) }
        let sshConfig = connection.effectiveSSHConfig(profile: profile)
        let isProfile = connection.sshProfileId != nil && profile != nil
        let secretOwnerId = (isProfile ? connection.sshProfileId : nil) ?? connection.id

        guard sshConfig.enabled else {
            return connection
        }

        // Load Keychain credentials off the main thread to avoid blocking UI
        let (storedSshPassword, keyPassphrase, totpSecret) = await Task.detached {
            if isProfile {
                let pwd = SSHProfileStorage.shared.loadSSHPassword(for: secretOwnerId)
                let phrase = SSHProfileStorage.shared.loadKeyPassphrase(for: secretOwnerId)
                let totp = SSHProfileStorage.shared.loadTOTPSecret(for: secretOwnerId)
                return (pwd, phrase, totp)
            } else {
                let pwd = ConnectionStorage.shared.loadSSHPassword(for: secretOwnerId)
                let phrase = ConnectionStorage.shared.loadKeyPassphrase(for: secretOwnerId)
                let totp = ConnectionStorage.shared.loadTOTPSecret(for: secretOwnerId)
                return (pwd, phrase, totp)
            }
        }.value

        let sshPassword = sshPasswordOverride ?? storedSshPassword

        let tunnelPort = try await SSHTunnelManager.shared.createTunnel(
            connectionId: connection.id,
            sshHost: sshConfig.host,
            sshPort: sshConfig.port,
            sshUsername: sshConfig.username,
            authMethod: sshConfig.authMethod,
            privateKeyPath: sshConfig.privateKeyPath,
            keyPassphrase: keyPassphrase,
            sshPassword: sshPassword,
            agentSocketPath: sshConfig.agentSocketPath,
            remoteHost: connection.host,
            remotePort: connection.port,
            jumpHosts: sshConfig.jumpHosts,
            totpMode: sshConfig.totpMode,
            totpSecret: totpSecret,
            totpAlgorithm: sshConfig.totpAlgorithm,
            totpDigits: sshConfig.totpDigits,
            totpPeriod: sshConfig.totpPeriod
        )

        // Adapt SSL config for tunnel: SSH already authenticates the server,
        // remote environment and aren't readable locally, so strip them and
        // use at least .preferred so libpq negotiates SSL when the server
        // requires it (SSH already authenticates the server itself).
        var tunnelSSL = connection.sslConfig
        if tunnelSSL.isEnabled {
            if tunnelSSL.verifiesCertificate {
                tunnelSSL.mode = .required
            }
            tunnelSSL.caCertificatePath = ""
            tunnelSSL.clientCertificatePath = ""
            tunnelSSL.clientKeyPath = ""
        }

        var effectiveFields = connection.additionalFields
        if connection.usePgpass {
            effectiveFields["pgpassOriginalHost"] = connection.host
            effectiveFields["pgpassOriginalPort"] = String(connection.port)
        }

        return DatabaseConnection(
            id: connection.id,
            name: connection.name,
            host: "127.0.0.1",
            port: tunnelPort,
            database: connection.database,
            username: connection.username,
            type: connection.type,
            sshConfig: SSHConfiguration(),
            sslConfig: tunnelSSL,
            additionalFields: effectiveFields
        )
    }

    // MARK: - Health Monitoring

    /// Start health monitoring for a connection
    private func startHealthMonitor(for connectionId: UUID) async {
        // Stop any existing monitor
        await stopHealthMonitor(for: connectionId)

        let monitor = ConnectionHealthMonitor(
            connectionId: connectionId,
            pingHandler: { [weak self] in
                guard let self else { return false }
                // Skip ping while a user query is in-flight to avoid racing
                // on the same non-thread-safe driver connection.
                // Allow ping if the query appears stuck (exceeds timeout + grace period).
                if await self.queriesInFlight[connectionId] != nil {
                    let queryTimeout = await TimeInterval(AppSettingsManager.shared.general.queryTimeoutSeconds)
                    let maxStale = max(queryTimeout, 300) // At least 5 minutes
                    if let startTime = await self.queryStartTimes[connectionId],
                       Date().timeIntervalSince(startTime) < maxStale {
                        return true // Query still within expected time
                    }
                    // Query appears stuck — fall through to ping
                }
                guard let mainDriver = await self.activeSessions[connectionId]?.driver else {
                    return false
                }
                do {
                    _ = try await mainDriver.execute(query: "SELECT 1")
                    return true
                } catch {
                    return false
                }
            },
            reconnectHandler: { [weak self] in
                guard let self else { return false }
                guard let session = await self.activeSessions[connectionId] else { return false }
                do {
                    let driver = try await self.trackOperation(sessionId: connectionId) {
                        try await self.reconnectDriver(for: session)
                    }
                    await self.updateSession(connectionId) { session in
                        session.driver = driver
                        session.status = .connected
                    }
                    return true
                } catch {
                    return false
                }
            },
            onStateChanged: { [weak self] id, state in
                guard let self else { return }
                await MainActor.run {
                    switch state {
                    case .healthy:
                        // Skip no-op write — avoid firing @Published when status is already .connected
                        if let session = self.activeSessions[id], !session.isConnected {
                            self.updateSession(id) { session in
                                session.status = .connected
                            }
                        }
                    case .reconnecting(let attempt):
                        Self.logger.info("Reconnecting session \(id) (attempt \(attempt))")
                        if case .connecting = self.activeSessions[id]?.status {
                            // Already .connecting — skip redundant write
                        } else {
                            self.updateSession(id) { session in
                                session.status = .connecting
                            }
                        }
                    case .failed:
                        Self.logger.error(
                            "Health monitoring failed for session \(id)")
                        self.updateSession(id) { session in
                            session.status = .error(String(localized: "Connection lost"))
                            session.clearCachedData()
                        }
                    case .checking:
                        break  // No UI update needed
                    }
                }
            }
        )

        healthMonitors[connectionId] = monitor
        await monitor.startMonitoring()
    }

    /// Creates a fresh driver, connects, and applies timeout for the given session.
    /// Uses the session's effective connection (SSH-tunneled if applicable).
    private func reconnectDriver(for session: ConnectionSession) async throws -> DatabaseDriver {
        // Disconnect existing driver
        session.driver?.disconnect()

        // Use effective connection (tunneled) if available, otherwise original
        let connectionForDriver = session.effectiveConnection ?? session.connection
        let driver = try DatabaseDriverFactory.createDriver(
            for: connectionForDriver,
            passwordOverride: session.cachedPassword
        )
        try await driver.connect()

        // Apply timeout
        let timeoutSeconds = AppSettingsManager.shared.general.queryTimeoutSeconds
        if timeoutSeconds > 0 {
            try await driver.applyQueryTimeout(timeoutSeconds)
        }

        await executeStartupCommands(
            session.connection.startupCommands, on: driver, connectionName: session.connection.name
        )

        if let savedSchema = session.currentSchema,
           let schemaDriver = driver as? SchemaSwitchable {
            do {
                try await schemaDriver.switchSchema(to: savedSchema)
            } catch {
                Self.logger.warning("Failed to restore schema '\(savedSchema)' on reconnect: \(error.localizedDescription)")
            }
        }

        // Restore database for MSSQL if session had a non-default database
        if let savedDatabase = session.currentDatabase,
           let adapter = driver as? PluginDriverAdapter {
            do {
                try await adapter.switchDatabase(to: savedDatabase)
            } catch {
                Self.logger.warning("Failed to restore database '\(savedDatabase)' on reconnect: \(error.localizedDescription)")
            }
        }

        return driver
    }

    /// Stop health monitoring for a connection
    private func stopHealthMonitor(for connectionId: UUID) async {
        if let monitor = healthMonitors.removeValue(forKey: connectionId) {
            await monitor.stopMonitoring()
        }
    }

    /// Reconnect the current session (called from toolbar Reconnect button)
    func reconnectCurrentSession() async {
        guard let sessionId = currentSessionId else { return }
        await reconnectSession(sessionId)
    }

    /// Reconnect a specific session by ID
    func reconnectSession(_ sessionId: UUID) async {
        guard let session = activeSessions[sessionId] else { return }

        Self.logger.info("Manual reconnect requested for: \(session.connection.name)")

        // Update status to connecting
        updateSession(sessionId) { session in
            session.status = .connecting
        }

        // Stop existing health monitor
        await stopHealthMonitor(for: sessionId)

        do {
            // Disconnect existing driver (re-fetch to avoid stale local reference)
            activeSessions[sessionId]?.driver?.disconnect()

            // Recreate SSH tunnel if needed and build effective connection
            let effectiveConnection = try await buildEffectiveConnection(for: session.connection)

            // Resolve password for prompt-for-password connections
            var passwordOverride = activeSessions[sessionId]?.cachedPassword
            if session.connection.promptForPassword && passwordOverride == nil {
                let isApiOnly = PluginManager.shared.connectionMode(for: session.connection.type) == .apiOnly
                guard let prompted = PasswordPromptHelper.prompt(
                    connectionName: session.connection.name,
                    isAPIToken: isApiOnly
                ) else {
                    updateSession(sessionId) { $0.status = .disconnected }
                    return
                }
                passwordOverride = prompted
            }

            // Create new driver and connect
            let driver = try DatabaseDriverFactory.createDriver(
                for: effectiveConnection,
                passwordOverride: passwordOverride
            )
            try await driver.connect()

            // Apply timeout
            let timeoutSeconds = AppSettingsManager.shared.general.queryTimeoutSeconds
            if timeoutSeconds > 0 {
                try await driver.applyQueryTimeout(timeoutSeconds)
            }

            await executeStartupCommands(
                session.connection.startupCommands, on: driver, connectionName: session.connection.name
            )

            if let savedSchema = activeSessions[sessionId]?.currentSchema,
               let schemaDriver = driver as? SchemaSwitchable {
                do {
                    try await schemaDriver.switchSchema(to: savedSchema)
                } catch {
                    Self.logger.warning("Failed to restore schema '\(savedSchema)' on reconnect: \(error.localizedDescription)")
                }
            }

            // Restore database for MSSQL if session had a non-default database
            if let savedDatabase = activeSessions[sessionId]?.currentDatabase,
               let adapter = driver as? PluginDriverAdapter {
                do {
                    try await adapter.switchDatabase(to: savedDatabase)
                } catch {
                    Self.logger.warning("Failed to restore database '\(savedDatabase)' on reconnect: \(error.localizedDescription)")
                }
            }

            // Update session
            updateSession(sessionId) { session in
                session.driver = driver
                session.status = .connected
                session.effectiveConnection = effectiveConnection
                if let passwordOverride {
                    session.cachedPassword = passwordOverride
                }
            }

            // Restart health monitoring if the plugin supports it
            let supportsHealthReconnect = PluginMetadataRegistry.shared.snapshot(
                forTypeId: session.connection.type.pluginTypeId
            )?.supportsHealthMonitor ?? true

            if supportsHealthReconnect {
                await startHealthMonitor(for: sessionId)
            }

            // Post connection notification for schema reload
            NotificationCenter.default.post(name: .databaseDidConnect, object: nil)

            Self.logger.info("Manual reconnect succeeded for: \(session.connection.name)")
        } catch {
            Self.logger.error("Manual reconnect failed: \(error.localizedDescription)")
            updateSession(sessionId) { session in
                session.status = .error(
                    String(localized: "Reconnect failed: \(error.localizedDescription)"))
                session.clearCachedData()
            }
        }
    }

    // MARK: - SSH Tunnel Recovery

    /// Handle SSH tunnel death by attempting reconnection with exponential backoff
    func handleSSHTunnelDied(connectionId: UUID) async {
        guard let session = activeSessions[connectionId] else { return }

        Self.logger.warning("SSH tunnel died for connection: \(session.connection.name)")

        // Stop health monitor before retrying to prevent stale pings during reconnect
        await stopHealthMonitor(for: connectionId)

        // Disconnect the stale driver and invalidate it so connectToSession
        // creates a fresh connection instead of short-circuiting on driver != nil
        session.driver?.disconnect()
        updateSession(connectionId) { session in
            session.driver = nil
            session.status = .connecting
        }

        let maxRetries = 5
        for retryCount in 0..<maxRetries {
            let delay = ExponentialBackoff.delay(for: retryCount + 1, maxDelay: 60)
            Self.logger.info("SSH reconnect attempt \(retryCount + 1)/\(maxRetries) in \(delay)s for: \(session.connection.name)")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            do {
                try await connectToSession(session.connection)
                Self.logger.info("Successfully reconnected SSH tunnel for: \(session.connection.name)")
                return
            } catch {
                Self.logger.warning("SSH reconnect attempt \(retryCount + 1) failed: \(error.localizedDescription)")
            }
        }

        Self.logger.error("All SSH reconnect attempts failed for: \(session.connection.name)")

        // Mark as error and release stale cached data
        updateSession(connectionId) { session in
            session.status = .error("SSH tunnel disconnected. Click to reconnect.")
            session.clearCachedData()
        }
    }

    // MARK: - Startup Commands

    nonisolated private static let startupLogger = Logger(subsystem: "com.TablePro", category: "DatabaseManager")

    @discardableResult
    nonisolated private func executeStartupCommands(
        _ commands: String?, on driver: DatabaseDriver, connectionName: String
    ) async -> [(statement: String, error: String)] {
        guard let commands, !commands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let statements = commands
            .components(separatedBy: CharacterSet(charactersIn: ";\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var failures: [(statement: String, error: String)] = []
        for statement in statements {
            do {
                _ = try await driver.execute(query: statement)
                Self.startupLogger.info(
                    "Startup command succeeded for '\(connectionName)': \(statement)"
                )
            } catch {
                Self.startupLogger.warning(
                    "Startup command failed for '\(connectionName)': \(statement) — \(error.localizedDescription)"
                )
                failures.append((statement: statement, error: error.localizedDescription))
            }
        }
        return failures
    }

    // MARK: - Schema Changes

    /// Execute schema changes (ALTER TABLE, CREATE INDEX, etc.) in a transaction
    func executeSchemaChanges(
        tableName: String,
        changes: [SchemaChange],
        databaseType: DatabaseType
    ) async throws {
        guard let sessionId = currentSessionId else {
            throw DatabaseError.notConnected
        }
        try await executeSchemaChanges(
            tableName: tableName,
            changes: changes,
            databaseType: databaseType,
            connectionId: sessionId
        )
    }

    /// Execute schema changes using an explicit connection ID (session-scoped)
    func executeSchemaChanges(
        tableName: String,
        changes: [SchemaChange],
        databaseType: DatabaseType,
        connectionId: UUID
    ) async throws {
        guard let driver = driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }

        try await trackOperation(sessionId: connectionId) {
            // For PostgreSQL PK modification, query the actual constraint name
            let pkConstraintName = await fetchPrimaryKeyConstraintName(
                tableName: tableName,
                databaseType: databaseType,
                changes: changes,
                driver: driver
            )

            guard let resolvedPluginDriver = (driver as? PluginDriverAdapter)?.schemaPluginDriver else {
                throw DatabaseError.unsupportedOperation
            }

            let generator = SchemaStatementGenerator(
                tableName: tableName,
                primaryKeyConstraintName: pkConstraintName,
                pluginDriver: resolvedPluginDriver
            )
            let statements = try generator.generate(changes: changes)

            // Execute in transaction
            try await driver.beginTransaction()

            do {
                for stmt in statements {
                    _ = try await driver.execute(query: stmt.sql)
                }

                try await driver.commitTransaction()

                // Post notification to refresh UI
                NotificationCenter.default.post(name: .refreshData, object: nil)
            } catch {
                // Rollback on error
                try? await driver.rollbackTransaction()
                throw DatabaseError.queryFailed("Schema change failed: \(error.localizedDescription)")
            }
        }
    }

    /// Query the actual primary key constraint name for PostgreSQL.
    /// Returns nil if the database is not PostgreSQL, no PK modification is pending,
    /// or the query fails (caller falls back to `{table}_pkey` convention).
    private func fetchPrimaryKeyConstraintName(
        tableName: String,
        databaseType: DatabaseType,
        changes: [SchemaChange],
        driver: DatabaseDriver
    ) async -> String? {
        // Only needed for PostgreSQL PK modifications
        guard databaseType == .postgresql || databaseType == .redshift || databaseType == .duckdb else { return nil }
        guard
            changes.contains(where: {
                if case .modifyPrimaryKey = $0 { return true }
                return false
            })
        else {
            return nil
        }

        // Query the actual constraint name from pg_constraint
        let escapedTable = tableName.replacingOccurrences(of: "'", with: "''")
        let schema: String
        if let schemaDriver = driver as? SchemaSwitchable {
            schema = schemaDriver.escapedSchema
        } else {
            schema = "public"
        }
        let query = """
            SELECT con.conname
            FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
            WHERE rel.relname = '\(escapedTable)'
              AND nsp.nspname = '\(schema)'
              AND con.contype = 'p'
            LIMIT 1
            """

        do {
            let result = try await driver.execute(query: query)
            if let row = result.rows.first, let name = row[0], !name.isEmpty {
                return name
            }
        } catch {
            // Query failed - fall back to convention in SchemaStatementGenerator
            Self.logger.warning(
                "Failed to query PK constraint name for '\(tableName)': \(error.localizedDescription)"
            )
        }

        return nil
    }
}
