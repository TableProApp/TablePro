//
//  DatabaseManager+Sessions.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import AppKit
import Combine
import Foundation
import os
import TableProPluginKit

// MARK: - Session Management

extension DatabaseManager {
    func connectToSession(_ connection: DatabaseConnection) async throws {
        if let existing = activeSessions[connection.id], existing.driver != nil {
            switchToSession(connection.id)
            return
        }

        MacAnalyticsProvider.shared.markConnectionAttempted()

        let resolvedConnection: DatabaseConnection
        if LicenseManager.shared.isFeatureAvailable(.envVarReferences) {
            resolvedConnection = EnvVarResolver.resolveConnection(connection)
        } else {
            resolvedConnection = connection
        }

        if activeSessions[connection.id] == nil {
            var session = ConnectionSession(connection: connection)
            session.status = .connecting
            setSession(session, for: connection.id)
        }
        currentSessionId = connection.id

        let effectiveConnection: DatabaseConnection
        do {
            effectiveConnection = try await buildEffectiveConnection(for: resolvedConnection)
        } catch {
            removeSessionEntry(for: connection.id)
            currentSessionId = nil
            throw error
        }

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

        var passwordOverride: String?
        if connection.promptForPassword {
            if let cached = activeSessions[connection.id]?.cachedPassword {
                passwordOverride = cached
            } else {
                let isApiOnly = pluginManager.connectionMode(for: connection.type) == .apiOnly
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

        let driver: DatabaseDriver
        do {
            driver = try await DatabaseDriverFactory.createDriver(
                for: effectiveConnection,
                passwordOverride: passwordOverride,
                awaitPlugins: true
            )
        } catch {
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

            let timeoutSeconds = AppSettingsManager.shared.general.queryTimeoutSeconds
            if timeoutSeconds > 0 {
                do {
                    try await driver.applyQueryTimeout(timeoutSeconds)
                } catch {
                    // Best-effort: some PostgreSQL-compatible databases like Aurora DSQL
                    // don't support SET statement_timeout.
                    Self.logger.warning(
                        "Query timeout not supported for \(connection.name): \(error.localizedDescription)"
                    )
                }
            }

            await executeStartupCommands(
                resolvedConnection.startupCommands, on: driver, connectionName: connection.name
            )

            if let schemaDriver = driver as? SchemaSwitchable {
                activeSessions[connection.id]?.currentSchema = schemaDriver.currentSchema
            }

            await executePostConnectActions(
                for: connection, resolvedConnection: resolvedConnection, driver: driver
            )

            // Batch all session mutations into a single write to fire objectWillChange once.
            if var session = activeSessions[connection.id] {
                session.driver = driver
                session.status = driver.status
                session.effectiveConnection = effectiveConnection
                if let passwordOverride {
                    session.cachedPassword = passwordOverride
                }
                setSession(session, for: connection.id)
            }

            MacAnalyticsProvider.shared.markConnectionSucceeded()
            AppEvents.shared.databaseDidConnect.send(DatabaseDidConnect(connectionId: connection.id))

            let supportsHealth = PluginMetadataRegistry.shared.snapshot(
                forTypeId: connection.type.pluginTypeId
            )?.supportsHealthMonitor ?? true

            if supportsHealth {
                await startHealthMonitor(for: connection.id)
            }
        } catch {
            if connection.resolvedSSHConfig.enabled {
                Task {
                    do {
                        try await SSHTunnelManager.shared.closeTunnel(connectionId: connection.id)
                    } catch {
                        Self.logger.warning("SSH tunnel cleanup failed for \(connection.name): \(error.localizedDescription)")
                    }
                }
            }

            // Remove failed session completely so UI returns to Welcome window.
            removeSessionEntry(for: connection.id)

            if currentSessionId == connection.id {
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
                   let savedDb = appSettingsStorage.loadLastDatabase(for: connection.id) {
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
                        activeSessions[connection.id]?.currentDatabase = String(initialDb)
                    } catch {
                        Self.logger.error("Failed to switch to database \(initialDb): \(error.localizedDescription)")
                    }
                } else {
                    activeSessions[connection.id]?.currentDatabase = "0"
                }
            case .selectSchemaFromLastSession:
                if let schemaDriver = driver as? SchemaSwitchable,
                   let savedSchema = appSettingsStorage.loadLastSchema(for: connection.id),
                   savedSchema != schemaDriver.currentSchema {
                    do {
                        try await schemaDriver.switchSchema(to: savedSchema)
                        activeSessions[connection.id]?.currentSchema = savedSchema
                    } catch {
                        Self.logger.warning("Failed to restore saved schema '\(savedSchema, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    // MARK: - Database / Schema Switching

    func switchDatabase(to database: String, for connectionId: UUID) async throws {
        guard let driver = driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }

        let pm = PluginMetadataRegistry.shared.snapshot(
            forTypeId: session(for: connectionId)?.connection.type.pluginTypeId ?? ""
        )

        if pm?.capabilities.requiresReconnectForDatabaseSwitch == true {
            updateSession(connectionId) { session in
                session.connection.database = database
                session.currentDatabase = database
                session.currentSchema = nil
            }
            appSettingsStorage.saveLastSchema(nil, for: connectionId)
            await SchemaService.shared.invalidate(connectionId: connectionId)
            await reconnectSession(connectionId)
        } else if pm?.capabilities.supportsSchemaSwitching == true,
                  let schemaDriver = driver as? SchemaSwitchable {
            try await schemaDriver.switchSchema(to: database)
            updateSession(connectionId) { session in
                session.currentSchema = database
            }
            appSettingsStorage.saveLastSchema(database, for: connectionId)
            return
        } else if let adapter = driver as? PluginDriverAdapter {
            try await adapter.switchDatabase(to: database)
            let grouping = pm?.schema.databaseGroupingStrategy ?? .byDatabase
            updateSession(connectionId) { session in
                session.currentDatabase = database
                if grouping == .bySchema {
                    session.currentSchema = pm?.schema.defaultSchemaName
                }
            }
        }

        appSettingsStorage.saveLastDatabase(database, for: connectionId)
    }

    func switchSchema(to schema: String, for connectionId: UUID) async throws {
        guard let driver = driver(for: connectionId),
              let schemaDriver = driver as? SchemaSwitchable else {
            throw DatabaseError.unsupportedOperation
        }

        try await schemaDriver.switchSchema(to: schema)
        updateSession(connectionId) { session in
            session.currentSchema = schema
        }
        appSettingsStorage.saveLastSchema(schema, for: connectionId)
    }

    func switchToSession(_ sessionId: UUID) {
        guard activeSessions[sessionId] != nil else { return }
        currentSessionId = sessionId
        updateSession(sessionId) { session in
            session.markActive()
        }
    }

    func disconnectSession(_ sessionId: UUID) async {
        let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")
        guard let session = activeSessions[sessionId] else {
            lifecycleLogger.info(
                "[close] disconnectSession: no session found connId=\(sessionId, privacy: .public)"
            )
            return
        }
        let totalStart = Date()
        lifecycleLogger.info(
            "[close] disconnectSession start connId=\(sessionId, privacy: .public) name=\(session.connection.name, privacy: .public) hasSSH=\(session.connection.resolvedSSHConfig.enabled)"
        )

        if session.connection.resolvedSSHConfig.enabled {
            let sshStart = Date()
            do {
                try await SSHTunnelManager.shared.closeTunnel(connectionId: session.connection.id)
            } catch {
                Self.logger.warning("SSH tunnel cleanup failed for \(session.connection.name): \(error.localizedDescription)")
            }
            lifecycleLogger.info(
                "[close] disconnectSession SSH tunnel close done connId=\(sessionId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(sshStart) * 1_000))"
            )
        }

        let hmStart = Date()
        await stopHealthMonitor(for: sessionId)
        lifecycleLogger.info(
            "[close] disconnectSession stopHealthMonitor done connId=\(sessionId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(hmStart) * 1_000))"
        )

        let driverStart = Date()
        session.driver?.disconnect()
        lifecycleLogger.info(
            "[close] disconnectSession driver.disconnect done connId=\(sessionId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(driverStart) * 1_000))"
        )
        removeSessionEntry(for: sessionId)

        await SchemaService.shared.invalidate(connectionId: sessionId)

        SchemaProviderRegistry.shared.clear(for: sessionId)

        SharedSidebarState.removeConnection(sessionId)

        if currentSessionId == sessionId {
            if let nextSessionId = activeSessions.keys.first {
                switchToSession(nextSessionId)
            } else {
                currentSessionId = nil
            }
        }
        lifecycleLogger.info(
            "[close] disconnectSession done connId=\(sessionId, privacy: .public) totalMs=\(Int(Date().timeIntervalSince(totalStart) * 1_000))"
        )
    }

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

    // Skips the write-back when no observable fields changed, avoiding spurious connectionStatusVersion bumps.
    func updateSession(_ sessionId: UUID, update: (inout ConnectionSession) -> Void) {
        guard var session = activeSessions[sessionId] else { return }
        let before = session
        let driverBefore = session.driver as AnyObject?
        update(&session)
        let driverAfter = session.driver as AnyObject?
        guard !session.isContentViewEquivalent(to: before) || driverBefore !== driverAfter else { return }
        setSession(session, for: sessionId)
    }

    internal func setSession(_ session: ConnectionSession, for connectionId: UUID) {
        activeSessions[connectionId] = session
        connectionStatusVersions[connectionId, default: 0] &+= 1
        AppEvents.shared.connectionStatusChanged.send(
            ConnectionStatusChange(connectionId: connectionId, status: session.status)
        )
    }

    internal func removeSessionEntry(for connectionId: UUID) {
        activeSessions.removeValue(forKey: connectionId)
        connectionStatusVersions.removeValue(forKey: connectionId)
        AppEvents.shared.connectionStatusChanged.send(
            ConnectionStatusChange(connectionId: connectionId, status: .disconnected)
        )
    }

    #if DEBUG
    internal func injectSession(_ session: ConnectionSession, for connectionId: UUID) {
        setSession(session, for: connectionId)
    }

    internal func removeSession(for connectionId: UUID) {
        removeSessionEntry(for: connectionId)
    }
    #endif
}
