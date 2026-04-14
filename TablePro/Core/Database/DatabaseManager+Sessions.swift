//
//  DatabaseManager+Sessions.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import AppKit
import Foundation
import os
import TableProPluginKit

// MARK: - Session Management

extension DatabaseManager {
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
                guard let prompted = await PasswordPromptHelper.prompt(
                    connectionName: connection.name,
                    isAPIToken: isApiOnly,
                    window: NSApp.keyWindow
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
            driver = try await DatabaseDriverFactory.createDriver(
                for: effectiveConnection,
                passwordOverride: passwordOverride,
                awaitPlugins: true
            )
        } catch {
            // Close tunnel if SSH was established
            if connection.resolvedSSHConfig.enabled {
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
            await executePostConnectActions(
                for: connection, resolvedConnection: resolvedConnection, driver: driver
            )

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
            if connection.resolvedSSHConfig.enabled {
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

    private func executePostConnectActions(
        for connection: DatabaseConnection,
        resolvedConnection: DatabaseConnection,
        driver: DatabaseDriver
    ) async {
        let postConnectActions = PluginMetadataRegistry.shared.snapshot(
            forTypeId: connection.type.pluginTypeId
        )?.postConnectActions ?? []

        for action in postConnectActions {
            switch action {
            case .selectDatabaseFromLastSession:
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
                    do {
                        try await (driver as? PluginDriverAdapter)?.switchDatabase(to: String(initialDb))
                    } catch {
                        Self.logger.error("Failed to switch to database \(initialDb): \(error.localizedDescription)")
                    }
                }
                activeSessions[connection.id]?.currentDatabase = String(initialDb)
            }
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
        if session.connection.resolvedSSHConfig.enabled {
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
    internal func setSession(_ session: ConnectionSession, for connectionId: UUID) {
        activeSessions[connectionId] = session
        connectionStatusVersions[connectionId, default: 0] &+= 1
        NotificationCenter.default.post(name: .connectionStatusDidChange, object: connectionId)
    }

    /// Remove a session and clean up its per-connection version counter.
    internal func removeSessionEntry(for connectionId: UUID) {
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
}
