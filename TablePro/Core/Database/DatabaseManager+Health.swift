//
//  DatabaseManager+Health.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import AppKit
import Foundation
import os
import TableProPluginKit

// MARK: - Health Monitoring

extension DatabaseManager {
    /// Start health monitoring for a connection
    internal func startHealthMonitor(for connectionId: UUID) async {
        Self.logger.info("startHealthMonitor called for \(connectionId) (existing monitors: \(self.healthMonitors.count))")
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
                    _ = try await mainDriver.execute(query: "SELECT 1")
                    return true
                } catch {
                    Self.logger.debug("Ping failed for \(connectionId): \(error.localizedDescription)")
                    return false
                }
            },
            reconnectHandler: { [weak self] in
                guard let self else { return false }
                guard let session = await self.activeSessions[connectionId] else { return false }
                do {
                    let result = try await self.trackOperation(sessionId: connectionId) {
                        try await self.reconnectDriver(for: session)
                    }
                    await self.updateSession(connectionId) { session in
                        session.driver = result.driver
                        session.effectiveConnection = result.effectiveConnection
                        session.status = .connected
                    }
                    return true
                } catch {
                    Self.logger.debug("Reconnect failed: \(error.localizedDescription)")
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

    /// Result of a driver reconnect, containing the new driver and its effective connection.
    internal struct ReconnectResult {
        let driver: DatabaseDriver
        let effectiveConnection: DatabaseConnection
    }

    /// Creates a fresh driver, connects, and applies timeout for the given session.
    /// For SSH-tunneled sessions, rebuilds the tunnel before connecting the driver.
    internal func reconnectDriver(for session: ConnectionSession) async throws -> ReconnectResult {
        // Disconnect existing driver
        session.driver?.disconnect()

        // Rebuild SSH tunnel if needed; otherwise reuse effective connection
        let connectionForDriver: DatabaseConnection
        if session.connection.resolvedSSHConfig.enabled {
            connectionForDriver = try await buildEffectiveConnection(for: session.connection)
        } else {
            connectionForDriver = session.effectiveConnection ?? session.connection
        }

        let driver = try await DatabaseDriverFactory.createDriver(
            for: connectionForDriver,
            passwordOverride: session.cachedPassword,
            awaitPlugins: true
        )

        do {
            try await driver.connect()
        } catch {
            driver.disconnect()
            if session.connection.resolvedSSHConfig.enabled {
                do {
                    try await SSHTunnelManager.shared.closeTunnel(connectionId: session.connection.id)
                } catch {
                    Self.logger.warning("Failed to close SSH tunnel during reconnect: \(error.localizedDescription)")
                }
            }
            throw error
        }

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

        return ReconnectResult(driver: driver, effectiveConnection: connectionForDriver)
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

            // Create new driver and connect
            let driver = try await DatabaseDriverFactory.createDriver(
                for: effectiveConnection,
                passwordOverride: passwordOverride,
                awaitPlugins: true
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
                    String(format: String(localized: "Reconnect failed: %@"), error.localizedDescription))
                session.clearCachedData()
            }
        }
    }
}
