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
    func connectToSession(
        _ requestedConnection: DatabaseConnection,
        passwordOverride incomingPasswordOverride: String? = nil,
        sshPasswordOverride: String? = nil
    ) async throws {
        let connection = resolvedConnectionDefinition(for: requestedConnection)

        /// Reusing the installed driver is right only while it still answers. A reconnect that gave
        /// up leaves one behind, and switching to it here reported success without replacing
        /// anything, which is how Reconnect came to be a button that returned to the same pane.
        if let existing = activeSessions[connection.id], existing.driver != nil, existing.liveness == .live {
            switchToSession(connection.id)
            return
        }

        MacAnalyticsProvider.shared.markConnectionAttempted()

        let attempt = connectionAttempts.begin(for: connection.id)
        disconnectReasons[connection.id] = nil
        userRequestedDisconnects.remove(connection.id)

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
        lastActiveSessionId = connection.id

        let effectiveConnection: DatabaseConnection
        do {
            if !resolvedConnection.enabledTunnelKinds.isEmpty {
                reportStage(.resolvingTunnel, for: connection.id)
            }
            effectiveConnection = try await buildEffectiveConnection(
                for: resolvedConnection,
                sshPasswordOverride: sshPasswordOverride
            )
        } catch {
            finalizeConnectionFailure(
                for: connection.id,
                cancelled: isAttemptCancelled(attempt, for: connection.id),
                error: error
            )
            throw error
        }

        if let script = resolvedConnection.preConnectScript,
           !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            do {
                reportStage(.runningPreConnectScript, for: connection.id)
                try await PreConnectHookRunner.run(script: script)
            } catch {
                finalizeConnectionFailure(
                    for: connection.id,
                    cancelled: isAttemptCancelled(attempt, for: connection.id),
                    error: error
                )
                throw error
            }
        }

        var passwordOverride: String? = incomingPasswordOverride
        if passwordOverride == nil, connection.promptForPassword, !pluginManager.hidesPassword(for: connection) {
            if let cached = activeSessions[connection.id]?.cachedPassword {
                passwordOverride = cached
            } else {
                let isApiOnly = pluginManager.connectionMode(for: connection.type) == .apiOnly
                reportStage(.awaitingCredentials, for: connection.id)
                guard let prompted = await PasswordPromptHelper.prompt(
                    connectionName: connection.name,
                    isAPIToken: isApiOnly,
                    window: NSApp.keyWindow
                ) else {
                    finalizeConnectionFailure(
                        for: connection.id,
                        cancelled: isAttemptCancelled(attempt, for: connection.id)
                    )
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
            let cancelled = isAttemptCancelled(attempt, for: connection.id)
            if !cancelled {
                closeActiveTunnel(for: connection)
            }
            finalizeConnectionFailure(for: connection.id, cancelled: cancelled, error: error)
            throw error
        }

        do {
            reportStage(.openingConnection, for: connection.id)
            try await driver.connectReporting(stage: stageReporter(for: connection.id))
            try Task.checkCancellation()
            try ensureAttemptIsCurrent(attempt, for: connection.id, driver: driver)

            reportStage(.preparingSession, for: connection.id)
            await applyTimeoutAndStartupCommands(
                on: driver,
                startupCommands: resolvedConnection.startupCommands,
                connectionName: connection.name
            )

            if let schemaDriver = driver as? SchemaSwitchable {
                activeSessions[connection.id]?.browseSchema = schemaDriver.currentSchema
            }
            if let reportingDriver = driver as? DatabaseReporting,
               let openedDatabase = reportingDriver.currentDatabase, !openedDatabase.isEmpty {
                activeSessions[connection.id]?.browseDatabase = openedDatabase
            }

            await executePostConnectActions(
                for: connection, resolvedConnection: resolvedConnection, driver: driver
            )

            try Task.checkCancellation()
            try ensureAttemptIsCurrent(attempt, for: connection.id, driver: driver)

            // Batch all session mutations into a single write to fire objectWillChange once.
            if var session = activeSessions[connection.id] {
                session.driver = driver
                session.status = driver.status
                session.effectiveConnection = effectiveConnection
                /// A connect is the answer to whatever went wrong before it, including a reconnect
                /// that gave up on this same entry, so the mark and the reason it carried go here.
                session.liveness = .live
                disconnectReasons.removeValue(forKey: connection.id)
                if let passwordOverride, !connection.usesAWSIAM {
                    session.cachedPassword = passwordOverride
                }
                setSession(session, for: connection.id)
            }

            connectionAttempts.finish(attempt, for: connection.id)

            MacAnalyticsProvider.shared.markConnectionSucceeded()
            AppEvents.shared.databaseDidConnect.send(DatabaseDidConnect(connectionId: connection.id))

            let supportsHealth = PluginMetadataRegistry.shared.snapshot(
                for: connection.type
            )?.supportsHealthMonitor ?? true

            if supportsHealth {
                await startHealthMonitor(for: connection.id)
            }
        } catch {
            let cancelled = isAttemptCancelled(attempt, for: connection.id)
            var reportedError = error
            if cancelled {
                driver.disconnect()
            } else {
                if let attributed = await attributedTunnelFailure(for: connection) {
                    reportedError = attributed
                }
                closeActiveTunnel(for: connection)
            }

            finalizeConnectionFailure(for: connection.id, cancelled: cancelled, error: reportedError)
            throw reportedError
        }
    }

    private func isAttemptCancelled(_ attempt: Int, for connectionId: UUID) -> Bool {
        Task.isCancelled || !connectionAttempts.isCurrent(attempt, for: connectionId)
    }

    private func ensureAttemptIsCurrent(
        _ attempt: Int,
        for connectionId: UUID,
        driver: DatabaseDriver
    ) throws {
        guard !isAttemptCancelled(attempt, for: connectionId) else {
            driver.disconnect()
            throw CancellationError()
        }
    }

    internal func resolvedConnectionDefinition(for connection: DatabaseConnection) -> DatabaseConnection {
        guard let stored = connectionStorage.loadConnection(id: connection.id) else { return connection }
        var resolved = connection
        resolved.safeModeLevel = stored.safeModeLevel
        return resolved
    }

    /// The classified error is recorded before the session entry goes away. Only the window that
    /// started an attempt learns the outcome directly, so without this a connect kicked off from
    /// anywhere else leaves the window to infer "the connection was closed" from an empty slot
    /// while the real reason is thrown away.
    internal func finalizeConnectionFailure(for connectionId: UUID, cancelled: Bool, error: Error? = nil) {
        guard !cancelled else { return }
        if let error, !ConnectionFailureClassifier.isUserCancelled(error) {
            recordDisconnectReason(ConnectionFailureClassifier.info(for: error), for: connectionId)
        }
        removeSessionEntry(for: connectionId)
        if lastActiveSessionId == connectionId {
            lastActiveSessionId = activeSessions.keys.first
        }
    }

    private func executePostConnectActions(
        for connection: DatabaseConnection,
        resolvedConnection: DatabaseConnection,
        driver: DatabaseDriver
    ) async {
        let postConnectActions = PluginMetadataRegistry.shared.snapshot(
            for: connection.type
        )?.postConnectActions ?? []

        for action in postConnectActions {
            switch action {
            case .selectDatabaseFromLastSession:
                if resolvedConnection.database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let adapter = driver as? PluginDriverAdapter,
                   let savedDb = appSettingsStorage.loadLastDatabase(for: connection.id) {
                    do {
                        try await adapter.switchDatabase(to: savedDb)
                        activeSessions[connection.id]?.browseDatabase = savedDb
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
                        activeSessions[connection.id]?.browseDatabase = String(initialDb)
                    } catch {
                        Self.logger.error("Failed to switch to database \(initialDb): \(error.localizedDescription)")
                    }
                } else {
                    activeSessions[connection.id]?.browseDatabase = "0"
                }
            case .selectSchemaFromLastSession:
                if let schemaDriver = driver as? SchemaSwitchable,
                   let savedSchema = appSettingsStorage.loadLastSchema(for: connection.id) {
                    do {
                        try await schemaDriver.switchSchemaIfNeeded(to: savedSchema)
                        activeSessions[connection.id]?.browseSchema = savedSchema
                    } catch {
                        Self.logger.warning("Failed to restore saved schema '\(savedSchema, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    // MARK: - Database / Schema Switching

    func switchDatabase(to database: String, for connectionId: UUID, persist: Bool = true) async throws {
        /// An engine that browses no database has nothing to switch to, and asking anyway reached
        /// the driver and surfaced its own "does not support database switching" as an alert on
        /// every table click (#2262). Refusing rather than reporting success, because the caller
        /// writes the toolbar's database on success.
        guard !database.isEmpty else {
            throw DatabaseError.unsupportedOperation
        }
        guard let driver = driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }

        let pm = session(for: connectionId).flatMap {
            PluginMetadataRegistry.shared.snapshot(for: $0.connection.type)
        }

        if pm?.capabilities.requiresReconnectForDatabaseSwitch == true {
            try await reconnectOntoDatabase(database, for: connectionId)
        } else if let adapter = driver as? PluginDriverAdapter {
            let grouping = pm?.schema.databaseGroupingStrategy ?? .byDatabase
            try await sessionDriverGate.withExclusiveAccess(connectionId) {
                try await adapter.switchDatabase(to: database)
                if grouping == .bySchema {
                    await resetSchema(on: adapter, to: pm?.schema.defaultSchemaName)
                }
            }
            updateSession(connectionId) { session in
                session.browseDatabase = database
                if grouping == .bySchema {
                    session.browseSchema = adapter.currentSchema
                }
            }
        }

        if persist {
            appSettingsStorage.saveLastDatabase(database, for: connectionId)
        }
        Self.logger.info(
            """
            switchDatabase landed conn=\(connectionId, privacy: .public) \
            database=\(database, privacy: .public) \
            browse=\(self.session(for: connectionId)?.resolvedBrowseDatabase ?? "none", privacy: .public)
            """
        )
        AppEvents.shared.browseContainerChanged.send(connectionId)
    }

    /// Reopens the connection on `database`, for an engine that cannot change database on a live
    /// connection.
    ///
    /// The session has to be pointed at the target before the attempt, because the reconnect
    /// builds its connection from those very fields. A failed attempt therefore has to put them
    /// back: leaving them on a database the connection never reached aims the next reconnect, and
    /// the next launch, at a database the user only tried once and could not open.
    private func reconnectOntoDatabase(_ database: String, for connectionId: UUID) async throws {
        guard let previous = session(for: connectionId) else {
            throw DatabaseError.notConnected
        }
        let previousDatabase = previous.connection.database
        let previousBrowseDatabase = previous.browseDatabase
        let previousBrowseSchema = previous.browseSchema
        let previousSavedSchema = appSettingsStorage.loadLastSchema(for: connectionId)

        updateSession(connectionId) { session in
            session.connection.database = database
            session.browseDatabase = database
            session.browseSchema = nil
            session.status = .connecting
        }
        appSettingsStorage.saveLastSchema(nil, for: connectionId)
        await SchemaService.shared.invalidate(connectionId: connectionId)

        do {
            try await reconnectSession(connectionId)
        } catch {
            updateSession(connectionId) { session in
                session.connection.database = previousDatabase
                session.browseDatabase = previousBrowseDatabase
                session.browseSchema = previousBrowseSchema
            }
            appSettingsStorage.saveLastSchema(previousSavedSchema, for: connectionId)
            throw error
        }
    }

    /// Moves the driver to the engine's default schema after a database switch.
    /// Writing the session's schema without moving the driver leaves object listings
    /// (driver schema) and table queries (session schema) on different schemas.
    private func resetSchema(on driver: any SchemaSwitchable, to defaultSchemaName: String?) async {
        guard let defaultSchemaName, !defaultSchemaName.isEmpty else { return }
        do {
            try await driver.switchSchemaIfNeeded(to: defaultSchemaName)
        } catch {
            Self.logger.warning(
                "Failed to reset schema to '\(defaultSchemaName, privacy: .public)' after a database switch: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func switchSchema(to schema: String, for connectionId: UUID) async throws {
        guard let driver = driver(for: connectionId),
              let schemaDriver = driver as? SchemaSwitchable else {
            throw DatabaseError.unsupportedOperation
        }

        try await sessionDriverGate.withExclusiveAccess(connectionId) {
            try await schemaDriver.switchSchema(to: schema)
        }
        updateSession(connectionId) { session in
            session.browseSchema = schema
        }
        appSettingsStorage.saveLastSchema(schema, for: connectionId)
        AppEvents.shared.currentSchemaChanged.send(connectionId)
        AppEvents.shared.browseContainerChanged.send(connectionId)
    }

    func switchToSession(_ sessionId: UUID) {
        guard activeSessions[sessionId] != nil else { return }
        lastActiveSessionId = sessionId
        updateSession(sessionId) { session in
            session.markActive()
        }
    }

    /// Ends a session. The window that was showing it stays open, so the tabs are written to disk
    /// first: `MainContentCoordinator.teardown()` clears them from memory and only the window-close
    /// path saves on its way out, which is how a disconnect used to take a window's tabs with it.
    func disconnectSession(_ sessionId: UUID, origin: SessionDisconnectOrigin = .appManaged) async {
        let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")
        guard let session = activeSessions[sessionId] else {
            lifecycleLogger.info(
                "[close] disconnectSession: no session found connId=\(sessionId, privacy: .public)"
            )
            return
        }
        /// Two disconnects for one session would both run the whole teardown, and the second one's
        /// tail would land after the user had already reconnected, tearing the new session down.
        guard !disconnectsInFlight.contains(sessionId) else {
            lifecycleLogger.info(
                "[close] disconnectSession: already in flight connId=\(sessionId, privacy: .public)"
            )
            return
        }
        disconnectsInFlight.insert(sessionId)
        defer { disconnectsInFlight.remove(sessionId) }

        tabStatePersister?.persistTabState(for: sessionId)
        if origin == .userRequested {
            userRequestedDisconnects.insert(sessionId)
        }
        let totalStart = Date()
        lifecycleLogger.info(
            "[close] disconnectSession start connId=\(sessionId, privacy: .public) name=\(session.connection.name, privacy: .public) hasSSH=\(session.connection.resolvedSSHConfig.enabled)"
        )

        if let tunnelManager = activeTunnelManager(for: session.connection) {
            let tunnelStart = Date()
            do {
                try await tunnelManager.closeTunnel(connectionId: session.connection.id)
            } catch {
                Self.logger.warning("Tunnel cleanup failed for \(session.connection.name): \(error.localizedDescription)")
            }
            lifecycleLogger.info(
                "[close] disconnectSession tunnel close done connId=\(sessionId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(tunnelStart) * 1_000))"
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
        await DatabaseTreeMetadataService.shared.handleDisconnect(connectionId: sessionId)

        SchemaProviderRegistry.shared.clear(for: sessionId)
        QueryCompletionProfileRegistry.shared.clear(connectionId: sessionId)
        ExternalSchemaTracker.shared.reset(connectionId: sessionId)

        SharedSidebarState.removeConnection(sessionId)
        SidebarViewModel.removeConnection(sessionId)
        HistoryPanelState.removeConnection(sessionId)
        QuickSwitcherCatalogStore.shared.removeConnection(sessionId)

        if lastActiveSessionId == sessionId {
            if let nextSessionId = activeSessions.keys.first {
                switchToSession(nextSessionId)
            } else {
                lastActiveSessionId = nil
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

    func observeConnectionUpdates() {
        connectionUpdatedCancellable = AppEvents.shared.connectionUpdated
            .receive(on: RunLoop.main)
            .sink { [weak self] connectionId in
                self?.reconcileStoredRecord(for: connectionId)
            }
    }

    func reconcileStoredRecord(for connectionId: UUID?) {
        let targetIds = connectionId.map { [$0] } ?? Array(activeSessions.keys)
        for id in targetIds {
            guard let session = activeSessions[id],
                  let stored = connectionStorage.loadConnection(id: id) else { continue }
            adoptDisplayFields(from: stored, into: session, for: id)
            setSafeModeLevel(stored.safeModeLevel, for: id)
        }
    }

    /// Carries the fields a live session only ever *displays* across from storage, and nothing else.
    ///
    /// This used to reconcile `safeModeLevel` alone, so everything else stayed frozen at connect
    /// time. `WorkspaceRailStore.resolve` reads `session.connection` for any live session, which
    /// made a rename or a recolour invisible in the rail until the next reconnect (#2398).
    ///
    /// The allowlist is deliberately narrow, and adopting the whole stored record instead would be
    /// unsafe: `reconnectOntoDatabase` builds its reconnect from `session.connection`, so letting
    /// an edited host, port, username or SSH config reach a live session would let the health
    /// monitor silently reconnect an open window, with its tabs, to a different server. An edit to
    /// those fields belongs to the next connect the user asks for, not to the one already running.
    private func adoptDisplayFields(
        from stored: DatabaseConnection,
        into session: ConnectionSession,
        for connectionId: UUID
    ) {
        var reconciled = session.connection
        reconciled.name = stored.name
        reconciled.color = stored.color
        reconciled.tagIds = stored.tagIds
        guard reconciled != session.connection else { return }

        var updated = session
        updated.connection = reconciled
        setSession(updated, for: connectionId)
    }

    func setSafeModeLevel(_ level: SafeModeLevel, for connectionId: UUID) {
        guard var session = activeSessions[connectionId] else { return }
        guard session.safeModeLevel != level || session.connection.safeModeLevel != level else { return }
        session.safeModeLevel = level
        session.connection.safeModeLevel = level
        setSession(session, for: connectionId)
        _ = connectionStorage.updateSafeModeLevel(level, for: connectionId)
    }

    internal func setSession(_ session: ConnectionSession, for connectionId: UUID) {
        activeSessions[connectionId] = session
        connectionStatusVersions[connectionId, default: 0] &+= 1
        AppEvents.shared.connectionStatusChanged.send(
            ConnectionStatusChange(connectionId: connectionId, status: session.status)
        )
    }

    /// Seeds the session entry before a window opens, so a window can resolve its connection and
    /// show the connecting surface for an attempt it does not own. A connection opened from a
    /// link or a database file is never in storage, so this is the only way the window can name
    /// what it is connecting to.
    internal func registerPendingSession(_ connection: DatabaseConnection) {
        guard activeSessions[connection.id] == nil else { return }
        var session = ConnectionSession(connection: connection)
        session.status = .connecting
        setSession(session, for: connection.id)
    }

    internal func reportStage(_ stage: ConnectionStage, for connectionId: UUID) {
        AppEvents.shared.connectionStageChanged.send(
            ConnectionStageChange(connectionId: connectionId, stage: stage)
        )
    }

    /// Handed to a driver, so it is called from whatever thread the handshake runs on and has
    /// to hop back before touching the main-actor event bus.
    internal func stageReporter(for connectionId: UUID) -> ConnectionStageReporter {
        { stage in
            Task { @MainActor in
                AppEvents.shared.connectionStageChanged.send(
                    ConnectionStageChange(connectionId: connectionId, stage: stage)
                )
            }
        }
    }

    internal func recordDisconnectReason(_ info: ConnectionFailureInfo, for connectionId: UUID) {
        disconnectReasons[connectionId] = info
    }

    /// Says that a session's driver has stopped answering, so the window stops presenting rows over
    /// it. The driver is left installed: it is the handle every metadata read, every query route and
    /// every reconnect still goes through, and taking it away would make an ordinary database switch
    /// on the engines that reconnect to perform one look like a dropped connection.
    ///
    /// `startedWith` is the generation check. A reconnect cannot be cancelled once the driver is
    /// inside a blocking connect, so a losing attempt completes late; without this it would mark a
    /// connection unreachable that a later attempt had already restored.
    internal func markSessionUnreachable(
        _ sessionId: UUID,
        startedWith driver: DatabaseDriver?,
        info: ConnectionFailureInfo?
    ) {
        guard let current = activeSessions[sessionId] else { return }
        guard current.driver === driver else { return }
        if let info { recordDisconnectReason(info, for: sessionId) }
        updateSession(sessionId) { session in
            session.liveness = .unreachable(info)
        }
    }

    /// The one way back. Every path that installs a working driver clears the mark with it, so a
    /// connection that recovers stops carrying the reason it once failed.
    internal func markSessionLive(_ sessionId: UUID) {
        guard activeSessions[sessionId] != nil else { return }
        disconnectReasons.removeValue(forKey: sessionId)
        updateSession(sessionId) { session in
            session.liveness = .live
        }
    }

    internal func markSessionRecovering(_ sessionId: UUID) {
        guard let current = activeSessions[sessionId], current.liveness == .live else { return }
        updateSession(sessionId) { session in
            session.liveness = .recovering
        }
    }

    internal func disconnectReason(for connectionId: UUID) -> ConnectionFailureInfo? {
        disconnectReasons[connectionId]
    }

    internal func wasDisconnectedByUser(_ connectionId: UUID) -> Bool {
        userRequestedDisconnects.contains(connectionId)
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
