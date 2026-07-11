//
//  DatabaseManager+Health.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import AppKit
import Combine
import Foundation
import os
import TableProPluginKit

// MARK: - Health Monitoring

extension DatabaseManager {
    internal enum ReconnectCredentialResolution: Equatable {
        case fail
        case retry(String)
        case abort
    }

    /// Start health monitoring for a connection
    internal func startHealthMonitor(for connectionId: UUID) async {
        Self.logger.info("startHealthMonitor called for \(connectionId) (existing monitors: \(self.healthMonitors.count))")
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
                        Self.logger.debug("Ping skipped — query in-flight for \(connectionId)")
                        return true // Query still within expected time
                    }
                    Self.logger.warning("Ping proceeding despite in-flight query (stale after \(maxStale)s) for \(connectionId)")
                }
                guard let mainDriver = await self.activeSessions[connectionId]?.driver else {
                    Self.logger.debug("Ping skipped — no active driver for \(connectionId)")
                    return false
                }
                do {
                    try await mainDriver.ping()
                    return true
                } catch {
                    Self.logger.debug("Ping failed for \(connectionId): \(error.localizedDescription)")
                    return false
                }
            },
            reconnectHandler: { [weak self] in
                guard let self else { return .abort }
                guard let session = await self.activeSessions[connectionId] else { return .abort }
                await SchemaService.shared.invalidate(connectionId: connectionId)
                await DatabaseTreeMetadataService.shared.handleReconnect(connectionId: connectionId)
                do {
                    guard let result = try await self.trackOperation(sessionId: connectionId, operation: {
                        try await self.reconnectDriver(for: session)
                    }) else {
                        await self.updateSession(connectionId) { session in
                            session.status = .disconnected
                        }
                        return .abort
                    }
                    await self.updateSession(connectionId) { session in
                        session.driver = result.driver
                        session.effectiveConnection = result.effectiveConnection
                        session.status = .connected
                        if let schemaDriver = result.driver as? SchemaSwitchable {
                            session.currentSchema = schemaDriver.currentSchema
                        }
                        if let cachedPassword = result.cachedPassword,
                           !session.connection.usesAWSIAM
                        {
                            session.cachedPassword = cachedPassword
                        }
                    }
                    return .success
                } catch {
                    Self.logger.debug("Reconnect failed: \(error.localizedDescription)")
                    // Auth failures are not transient. Retrying with the same expired
                    // credential just re-prompts on every attempt, so stop the loop.
                    if await self.isAuthenticationFailure(error) {
                        await self.updateSession(connectionId) { session in
                            session.status = .error(
                                String(format: String(localized: "Reconnect failed: %@"), error.localizedDescription)
                            )
                        }
                        return .abort
                    }
                    return .retry
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
                            // Already .connecting, skip redundant write
                        } else {
                            self.updateSession(id) { session in
                                session.status = .connecting
                            }
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

    /// Result of a driver reconnect, containing the new driver and its effective connection.
    internal struct ReconnectResult {
        let driver: DatabaseDriver
        let effectiveConnection: DatabaseConnection
        let cachedPassword: String?
    }

    /// Creates a fresh driver, connects, and applies timeout for the given session.
    /// For SSH-tunneled sessions, rebuilds the tunnel before connecting the driver.
    internal func reconnectDriver(for session: ConnectionSession) async throws -> ReconnectResult? {
        session.driver?.disconnect()

        // Rebuild the tunnel if needed; otherwise reuse effective connection
        let connectionForDriver: DatabaseConnection
        if session.connection.activeTunnelKind != nil {
            connectionForDriver = try await buildEffectiveConnection(for: session.connection)
        } else {
            connectionForDriver = session.effectiveConnection ?? session.connection
        }

        guard let connectResult = try await connectReconnectDriver(
            for: session,
            effectiveConnection: connectionForDriver,
            passwordOverride: session.cachedPassword
        ) else {
            return nil
        }
        let driver = connectResult.driver

        await applyTimeoutAndStartupCommands(
            on: driver,
            startupCommands: session.connection.startupCommands,
            connectionName: session.connection.name
        )
        await restoreSchemaAndDatabase(
            on: driver,
            savedSchema: session.currentSchema,
            savedDatabase: databaseSwitchRequiresReconnect(session.connection) ? nil : session.currentDatabase
        )

        return ReconnectResult(
            driver: driver,
            effectiveConnection: connectionForDriver,
            cachedPassword: connectResult.cachedPassword
        )
    }

    func applyTimeoutAndStartupCommands(
        on driver: DatabaseDriver,
        startupCommands: String?,
        connectionName: String
    ) async {
        let timeoutSeconds = AppSettingsManager.shared.general.queryTimeoutSeconds
        do {
            try await driver.applyQueryTimeout(timeoutSeconds)
        } catch {
            Self.logger.warning(
                "Query timeout not supported for \(connectionName): \(error.localizedDescription)"
            )
        }

        await executeStartupCommands(startupCommands, on: driver, connectionName: connectionName)
    }

    private func databaseSwitchRequiresReconnect(_ connection: DatabaseConnection) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: connection.type.pluginTypeId)?
            .capabilities.requiresReconnectForDatabaseSwitch ?? false
    }

    func restoreSchemaAndDatabase(
        on driver: DatabaseDriver,
        savedSchema: String?,
        savedDatabase: String?
    ) async {
        if let savedSchema, let schemaDriver = driver as? SchemaSwitchable {
            do {
                try await schemaDriver.switchSchema(to: savedSchema)
            } catch {
                Self.logger.warning("Failed to restore schema '\(savedSchema)' on reconnect: \(error.localizedDescription)")
            }
        }

        if let savedDatabase, let adapter = driver as? PluginDriverAdapter {
            do {
                try await adapter.switchDatabase(to: savedDatabase)
            } catch {
                Self.logger.warning("Failed to restore database '\(savedDatabase)' on reconnect: \(error.localizedDescription)")
            }
        }
    }

    /// Stop health monitoring for a connection
    internal func stopHealthMonitor(for connectionId: UUID) async {
        if let monitor = healthMonitors.removeValue(forKey: connectionId) {
            Self.logger.info("stopHealthMonitor: stopping monitor for \(connectionId) (remaining: \(self.healthMonitors.count))")
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

        updateSession(sessionId) { session in
            session.status = .connecting
        }

        await SchemaService.shared.invalidate(connectionId: sessionId)
        await DatabaseTreeMetadataService.shared.handleReconnect(connectionId: sessionId)

        await stopHealthMonitor(for: sessionId)

        do {
            // Disconnect existing driver (re-fetch to avoid stale local reference)
            activeSessions[sessionId]?.driver?.disconnect()

            // Recreate SSH tunnel if needed and build effective connection
            let effectiveConnection = try await buildEffectiveConnection(for: session.connection)

            // Resolve password for prompt-for-password connections
            var passwordOverride = activeSessions[sessionId]?.cachedPassword
            if session.connection.promptForPassword,
               !pluginManager.hidesPassword(for: session.connection),
               passwordOverride == nil
            {
                let isApiOnly = pluginManager.connectionMode(for: session.connection.type) == .apiOnly
                guard let prompted = await PasswordPromptHelper.prompt(
                    connectionName: session.connection.name,
                    isAPIToken: isApiOnly,
                    window: NSApp.keyWindow
                ) else {
                    updateSession(sessionId) { $0.status = .disconnected }
                    return
                }
                passwordOverride = prompted
            }

            guard let connectResult = try await connectReconnectDriver(
                for: session,
                effectiveConnection: effectiveConnection,
                passwordOverride: passwordOverride
            ) else {
                updateSession(sessionId) { $0.status = .disconnected }
                return
            }
            let driver = connectResult.driver

            await applyTimeoutAndStartupCommands(
                on: driver,
                startupCommands: session.connection.startupCommands,
                connectionName: session.connection.name
            )
            await restoreSchemaAndDatabase(
                on: driver,
                savedSchema: activeSessions[sessionId]?.currentSchema,
                savedDatabase: databaseSwitchRequiresReconnect(session.connection) ? nil : activeSessions[sessionId]?.currentDatabase
            )

            updateSession(sessionId) { session in
                session.driver = driver
                session.status = .connected
                session.effectiveConnection = effectiveConnection
                if let schemaDriver = driver as? SchemaSwitchable {
                    session.currentSchema = schemaDriver.currentSchema
                }
                if let cachedPassword = connectResult.cachedPassword,
                   !session.connection.usesAWSIAM
                {
                    session.cachedPassword = cachedPassword
                }
            }

            // Restart health monitoring if the plugin supports it
            let supportsHealthReconnect = PluginMetadataRegistry.shared.snapshot(
                forTypeId: session.connection.type.pluginTypeId
            )?.supportsHealthMonitor ?? true

            if supportsHealthReconnect {
                await startHealthMonitor(for: sessionId)
            }

            AppEvents.shared.databaseDidConnect.send(DatabaseDidConnect(connectionId: sessionId))

            Self.logger.info("Manual reconnect succeeded for: \(session.connection.name)")
        } catch {
            Self.logger.error("Manual reconnect failed: \(error.localizedDescription)")
            updateSession(sessionId) { session in
                session.status = .error(
                    String(format: String(localized: "Reconnect failed: %@"), error.localizedDescription))
                session.clearCachedData()
            }
        }
    }

    internal func connectReconnectDriver(
        for session: ConnectionSession,
        effectiveConnection: DatabaseConnection,
        passwordOverride initialPasswordOverride: String?
    ) async throws -> (driver: DatabaseDriver, cachedPassword: String?)? {
        var passwordOverride = initialPasswordOverride

        while true {
            let driver = try await DatabaseDriverFactory.createDriver(
                for: effectiveConnection,
                passwordOverride: passwordOverride,
                awaitPlugins: true
            )

            do {
                try await driver.connect()
                return (driver, passwordOverride)
            } catch {
                driver.disconnect()

                switch await reconnectCredentialResolution(
                    for: session,
                    error: error,
                    currentPassword: passwordOverride
                ) {
                case .retry(let newPassword):
                    passwordOverride = newPassword
                case .abort:
                    await closeReconnectTunnels(for: session.connection)
                    return nil
                case .fail:
                    await closeReconnectTunnels(for: session.connection)
                    throw error
                }
            }
        }
    }

    internal func reconnectCredentialResolution(
        for session: ConnectionSession,
        error: Error,
        currentPassword: String?,
        prompt: @escaping @MainActor (_ connectionName: String, _ isAPIToken: Bool, _ window: NSWindow?) async -> String? = PasswordPromptHelper.prompt
    ) async -> ReconnectCredentialResolution {
        guard session.connection.promptForPassword,
              !pluginManager.hidesPassword(for: session.connection),
              isAuthenticationFailure(error)
        else {
            return .fail
        }

        let isApiOnly = pluginManager.connectionMode(for: session.connection.type) == .apiOnly
        guard let prompted = await prompt(
            session.connection.name,
            isApiOnly,
            NSApp.keyWindow
        ) else {
            return .abort
        }

        if prompted == currentPassword {
            return .fail
        }

        return .retry(prompted)
    }

    private static let invalidAuthorizationSQLState = "28000"
    private static let mysqlAccessDeniedErrorCode = 1_045

    internal func isAuthenticationFailure(_ error: Error) -> Bool {
        if let pluginError = error as? any PluginDriverError {
            if pluginError.pluginSqlState == Self.invalidAuthorizationSQLState {
                return true
            }
            if pluginError.pluginErrorCode == Self.mysqlAccessDeniedErrorCode {
                return true
            }
            return messageIndicatesAuthenticationFailure(pluginError.pluginErrorMessage)
        }
        return messageIndicatesAuthenticationFailure(error.localizedDescription)
    }

    private func messageIndicatesAuthenticationFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("access denied")
            || lowered.contains("authentication failed")
            || lowered.contains("invalid credentials")
    }

    private func closeReconnectTunnels(for connection: DatabaseConnection) async {
        guard let tunnelManager = activeTunnelManager(for: connection) else { return }
        do {
            try await tunnelManager.closeTunnel(connectionId: connection.id)
        } catch {
            Self.logger.warning("Failed to close tunnel during reconnect: \(error.localizedDescription)")
        }
    }
}
