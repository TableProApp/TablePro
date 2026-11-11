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

    // "Never" builds no monitor at all: verifyBeforeUse checks the connection when the user reaches for it.
    internal func startHealthMonitor(for connectionId: UUID) async {
        await stopHealthMonitor(for: connectionId)

        // A placeholder registered before its connect finishes has nothing to check yet.
        guard activeSessions[connectionId]?.driver != nil else { return }
        guard supportsHealthChecks(connectionId) else { return }

        guard AppSettingsManager.shared.general.connectionHealthCheck.interval != nil else {
            Self.logger.info("Health monitoring is on demand, starting no monitor for \(connectionId)")
            return
        }

        Self.logger.info("startHealthMonitor called for \(connectionId) (existing monitors: \(self.healthMonitors.count))")

        let monitor = ConnectionHealthMonitor(
            connectionId: connectionId,
            pingInterval: { await AppSettingsManager.shared.general.connectionHealthCheck.interval },
            pingHandler: { [weak self] in
                guard let self else { return false }
                await self.closeIdleOpenedLanes(for: connectionId)
                if await self.queriesInFlight[connectionId] != nil {
                    Self.logger.debug("Ping skipped, operation in flight for \(connectionId)")
                    return true
                }
                guard let mainDriver = await self.activeSessions[connectionId]?.driver else {
                    Self.logger.debug("Ping skipped, no active driver for \(connectionId)")
                    return false
                }
                await self.notePinged(mainDriver, for: connectionId)
                do {
                    try await mainDriver.ping()
                    await self.noteAnsweredPing(connectionId, driver: mainDriver)
                    return true
                } catch {
                    Self.logger.debug("Ping failed for \(connectionId): \(error.publicLogShape, privacy: .public)")
                    return false
                }
            },
            onPingFailed: { [weak self] in
                guard let self else { return .handedOff }
                return await self.healthCheckFailed(connectionId)
            }
        )

        healthMonitors[connectionId] = monitor
        await monitor.startMonitoring()
    }

    internal func healthCheckFailed(_ connectionId: UUID) -> ConnectionHealthMonitor.FailureHandling {
        // A monitor someone already stopped reports to nobody: whoever stopped it is dialing.
        guard healthMonitors[connectionId] != nil else { return .handedOff }
        let driver = activeSessions[connectionId]?.driver
        // A database switch parked the checked driver; the parked one is checked again before use.
        if let driver, let pinged = monitorPingedDrivers[connectionId], pinged !== driver { return .ignored }
        // The monitor ends itself once it hands off, so the entry goes without waiting on it.
        healthMonitors.removeValue(forKey: connectionId)
        beginRecovery(for: connectionId, cause: .stoppedResponding)
        return .handedOff
    }

    private func noteAnsweredPing(_ connectionId: UUID, driver: DatabaseDriver) {
        markSessionVerified(connectionId)
        // A renewed lease that failed leaves .recovering with no loop; an answer is the way back.
        guard let session = activeSessions[connectionId],
              session.driver === driver,
              session.liveness == .recovering,
              recoveryLoops[connectionId] == nil
        else { return }
        markSessionLive(connectionId)
    }

    // A lease renewal or a failed check before use redials through the session's loop, never beside it.
    internal func performHealthMonitorReconnect(
        connectionId: UUID,
        failedDriver: ObjectIdentifier? = nil
    ) async -> ReconnectOutcome {
        guard let session = activeSessions[connectionId] else { return .abort }
        // A database switch may have parked the checked driver; reconnecting would take the new one's transaction.
        if let failedDriver, let current = session.driver, ObjectIdentifier(current) != failedDriver {
            return .success
        }
        return await recoverNow(connectionId, cause: .stoppedResponding)
    }

    // One unattended attempt by the recovery loop, owned by `generation` from the first line to the last.
    // The schema cache is prepared for reload, never invalidated: a background reconnect is not a teardown.
    internal func performRecoveryAttempt(
        connectionId: UUID,
        failedDriver: ObjectIdentifier,
        generation: Int
    ) async -> ReconnectOutcome {
        guard let session = activeSessions[connectionId] else { return .abort }
        if let current = session.driver, ObjectIdentifier(current) != failedDriver {
            return .success
        }
        // Every give-up below is fenced on this driver: a reconnect blocked in a C call completes late.
        let attemptedDriver = session.driver
        // Begun before anything suspends, so a database switch cannot promote another connection meanwhile.
        MetadataConnectionPool.shared.beginTransportReplacement(connectionId: connectionId)
        defer { MetadataConnectionPool.shared.endTransportReplacement(connectionId: connectionId) }
        // Debug drivers are dedicated connections the pool's fence does not hold back.
        await RoutineDebugSessions.shared.stopAll(connectionId: connectionId)
        defer { RoutineDebugSessions.shared.reopenAdmission(for: connectionId) }
        await SchemaService.shared.prepareForReload(connectionId: connectionId)
        await DatabaseTreeMetadataService.shared.handleReconnect(connectionId: connectionId)
        // A switch that landed during the suspensions installed a connection that never failed.
        guard activeSessions[connectionId]?.driver === attemptedDriver else { return .success }
        guard isCurrentAttempt(generation, for: connectionId) else { return .abort }

        do {
            // Never prompts: nobody asked for this reconnect, and a sheet here blocked Disconnect and Quit.
            guard let result = try await trackOperation(sessionId: connectionId, operation: {
                try await self.reconnectDriver(for: session, allowsCredentialPrompt: false, generation: generation)
            }) else {
                guard isCurrentAttempt(generation, for: connectionId) else { return .abort }
                updateSession(connectionId) { session in
                    session.status = .disconnected
                }
                markSessionUnreachable(connectionId, startedWith: attemptedDriver, info: Self.declinedReconnectInfo)
                return .abort
            }
            // A losing attempt finishes late; adopting it would replace the driver a newer connect installed.
            guard activeSessions[connectionId]?.driver === attemptedDriver,
                  isCurrentAttempt(generation, for: connectionId)
            else {
                result.driver.disconnect()
                return .abort
            }
            let warning = openingWarning(
                driver: result.driver,
                startupFailures: result.startupFailures,
                restoreWarning: result.restoreWarning,
                for: connectionId
            )
            updateSession(connectionId) { session in
                session.driver = result.driver
                session.effectiveConnection = result.effectiveConnection
                session.status = .connected
                session.connectionWarning = warning
                if let schemaDriver = result.driver as? SchemaSwitchable {
                    session.browseSchema = schemaDriver.currentSchema
                }
                if let cachedPassword = result.cachedPassword,
                   !session.connection.usesIAMToken
                {
                    session.cachedPassword = cachedPassword
                }
            }
            markSessionLive(connectionId)
            AppEvents.shared.databaseDidConnect.send(DatabaseDidConnect(connectionId: connectionId))
            return .success
        } catch {
            Self.logger.debug("Reconnect failed: \(error.publicLogShape, privacy: .public)")
            guard isCurrentAttempt(generation, for: connectionId) else { return .abort }
            switch reconnectVerdict(for: error) {
            case .retry(let failure):
                return .retry(failure)
            case .stop(let failure):
                Self.logger.info("Reconnect for \(connectionId) stopped: \(error.publicLogShape, privacy: .public)")
                endUnattendedReconnect(connectionId, startedWith: attemptedDriver, failure: failure)
                return .abort
            }
        }
    }

    // Read before the driver is closed and replaced, which prunes the hold. The user's next statement there
    // is refused once, as on a lane, instead of running outside the transaction it was written for.
    internal func noteTransactionLost(with driver: DatabaseDriver?, for connectionId: UUID) {
        guard let driver, let session = activeSessions[connectionId] else { return }
        let lost = sessionTransactions.holds(for: connectionId).filter { sessionTransactions.driver(for: $0) === driver }
        for hold in lost {
            sessionLanes.markTransactionLost(
                database: hold.key.lane ?? session.resolvedBrowseDatabase,
                for: connectionId
            )
        }
    }

    internal func reconnectVerdict(for error: Error) -> ConnectionFailureClassifier.ReconnectVerdict {
        if let tlsError = error as? SSLHandshakeError {
            return ConnectionFailureClassifier.reconnectVerdict(for: tlsError)
        }
        // A refusal that needs a person gets the same answer on every retry.
        if error is EnvVarReferenceConsentError || error is PreConnectScriptConsentError {
            return .stop(ConnectionFailureClassifier.info(for: error))
        }
        guard isAuthenticationFailure(error) else { return .retry(nil) }
        let message = String(format: String(localized: "Reconnect failed: %@"), error.localizedDescription)
        return .stop(ConnectionFailureInfo(message: message))
    }

    private func isCurrentAttempt(_ generation: Int, for connectionId: UUID) -> Bool {
        connectionAttempts.isCurrent(generation, for: connectionId)
    }

    private func requireCurrentAttempt(_ generation: Int, for connectionId: UUID) throws {
        guard isCurrentAttempt(generation, for: connectionId) else { throw CancellationError() }
    }

    private func endUnattendedReconnect(
        _ connectionId: UUID,
        startedWith attemptedDriver: DatabaseDriver?,
        failure: ConnectionFailureInfo
    ) {
        guard activeSessions[connectionId]?.driver === attemptedDriver else { return }
        updateSession(connectionId) { session in
            session.status = .error(failure.message)
        }
        markSessionUnreachable(connectionId, startedWith: attemptedDriver, info: failure)
    }

    internal static let declinedReconnectInfo = ConnectionFailureInfo(
        message: String(localized: "The connection was closed and reconnecting was cancelled.")
    )

    internal struct ReconnectResult {
        let driver: DatabaseDriver
        let effectiveConnection: DatabaseConnection
        let cachedPassword: String?
        let startupFailures: [StartupCommandFailure]
        let restoreWarning: String?
    }

    // Rebuilds the tunnel for a tunneled session before connecting the new driver. Tunnels are keyed by
    // connection, so every step after a suspension asks again whether this attempt still owns the slot.
    internal func reconnectDriver(
        for session: ConnectionSession,
        allowsCredentialPrompt: Bool,
        generation: Int
    ) async throws -> ReconnectResult? {
        let connectionId = session.connection.id
        noteTransactionLost(with: session.driver, for: connectionId)
        session.driver?.disconnect()
        // Resolved as the connect resolved it; a reference that lost its approval needs a person.
        let connection = try await envVarReferenceConsent.resolve(session.connection, trigger: .background)
        let preparedConfiguration = try await DatabaseDriverFactory.prepareConfiguration(for: connection)
        let deadline = ConnectionDeadline(configuredSeconds: connection.connectTimeoutSeconds)
        try requireCurrentAttempt(generation, for: connectionId)

        let connectionForDriver: DatabaseConnection
        if connection.activeTunnelKind != nil {
            // A rebuilt tunnel moves to a new local port, stranding every other database's connection.
            await closeTransportLanes(for: connectionId) { self.isCurrentAttempt(generation, for: connectionId) }
            connectionForDriver = try await buildEffectiveConnection(
                for: connection,
                deadline: deadline,
                ownsAttempt: { self.isCurrentAttempt(generation, for: connectionId) }
            )
            try requireCurrentAttempt(generation, for: connectionId)
        } else {
            connectionForDriver = session.effectiveConnection ?? session.connection
        }

        guard let connectResult = try await connectReconnectDriver(
            for: session,
            effectiveConnection: connectionForDriver,
            passwordOverride: session.cachedPassword,
            allowsCredentialPrompt: allowsCredentialPrompt,
            deadline: deadline,
            preparedConfiguration: preparedConfiguration,
            ownsAttempt: { self.isCurrentAttempt(generation, for: connectionId) }
        ) else {
            return nil
        }
        let driver = connectResult.driver
        guard isCurrentAttempt(generation, for: connectionId) else {
            driver.disconnect()
            throw CancellationError()
        }

        let startupFailures = await applyTimeoutAndStartupCommands(
            on: driver,
            queryTimeoutSeconds: session.effectiveQueryTimeoutSeconds,
            startupCommands: session.connection.startupCommands,
            connectionName: session.connection.name
        )
        let restoreWarning = await restoreSchemaAndDatabase(
            on: driver,
            savedSchema: session.browseSchema,
            savedDatabase: databaseSwitchRequiresReconnect(session.connection) ? nil : session.browseDatabase
        )

        return ReconnectResult(
            driver: driver,
            effectiveConnection: connectionForDriver,
            cachedPassword: connectResult.cachedPassword,
            startupFailures: startupFailures,
            restoreWarning: restoreWarning
        )
    }

    func applyTimeoutAndStartupCommands(
        on driver: DatabaseDriver,
        queryTimeoutSeconds: Int,
        startupCommands: String?,
        connectionName: String
    ) async -> [StartupCommandFailure] {
        do {
            try await driver.applyQueryTimeout(queryTimeoutSeconds)
        } catch {
            Self.logger.warning(
                "Query timeout not supported for \(connectionName): \(error.localizedDescription)"
            )
        }

        return await executeStartupCommands(startupCommands, on: driver, connectionName: connectionName)
    }

    private func databaseSwitchRequiresReconnect(_ connection: DatabaseConnection) -> Bool {
        PluginMetadataRegistry.shared.snapshot(for: connection.type)?
            .capabilities.requiresReconnectForDatabaseSwitch ?? false
    }

    // The reconnected session stays on the server's default when a restore fails, which the window would not show.
    func restoreSchemaAndDatabase(
        on driver: DatabaseDriver,
        savedSchema: String?,
        savedDatabase: String?
    ) async -> String? {
        var warnings: [String?] = []
        // The schema lives inside the database, and a database switch can leave the driver on none.
        if let savedDatabase, let adapter = driver as? PluginDriverAdapter {
            do {
                try await adapter.switchDatabase(to: savedDatabase)
            } catch {
                Self.logger.warning("Failed to restore database '\(savedDatabase)' on reconnect: \(error.localizedDescription)")
                warnings.append(String(
                    format: String(localized: "Reconnecting could not reopen the database %1$@: %2$@"),
                    savedDatabase, error.localizedDescription
                ))
            }
        }

        if let savedSchema, let schemaDriver = driver as? SchemaSwitchable {
            do {
                try await schemaDriver.switchSchema(to: savedSchema)
            } catch {
                Self.logger.warning("Failed to restore schema '\(savedSchema)' on reconnect: \(error.localizedDescription)")
                warnings.append(String(
                    format: String(localized: "Reconnecting could not reopen the schema %1$@: %2$@"),
                    savedSchema, error.localizedDescription
                ))
            }
        }
        return Self.joinedWarning(warnings)
    }

    internal func stopHealthMonitor(for connectionId: UUID) async {
        if let monitor = healthMonitors.removeValue(forKey: connectionId) {
            Self.logger.info("stopHealthMonitor: stopping monitor for \(connectionId) (remaining: \(self.healthMonitors.count))")
            await monitor.stopMonitoring()
        }
    }

    // Throws so the caller decides what to persist: a failed database switch once saved an unreachable
    // database as the default. A declined password prompt throws CancellationError, which is not a server refusal.
    func reconnectSession(_ sessionId: UUID) async throws {
        guard let session = activeSessions[sessionId] else {
            throw DatabaseError.notConnected
        }

        Self.logger.info("Manual reconnect requested for: \(session.connection.name)")

        // This reconnect owns the session: no loop or monitor may redial or rebuild the tunnel beside it.
        supersedeRecovery(for: sessionId)
        await stopHealthMonitor(for: sessionId)
        let generation = connectionAttempts.begin(for: sessionId)
        defer { connectionAttempts.finish(generation, for: sessionId) }

        let attemptedDriver = session.driver

        updateSession(sessionId) { session in
            session.status = .connecting
        }

        await SchemaService.shared.prepareForReload(connectionId: sessionId)
        await DatabaseTreeMetadataService.shared.handleReconnect(connectionId: sessionId)
        // Only a rebuilt tunnel or a session that stopped answering moves the pooled transport; a switch
        // over a live, direct connection must not withdraw an open another database's load is waiting on.
        let replacesPooledTransport = session.connection.activeTunnelKind != nil || session.liveness != .live
        if replacesPooledTransport {
            // A debug target dialed through this transport would be left holding its locks once it goes.
            await RoutineDebugSessions.shared.stopAll(connectionId: sessionId)
            MetadataConnectionPool.shared.beginTransportReplacement(connectionId: sessionId)
            await closeTransportLanes(for: sessionId) { self.isCurrentAttempt(generation, for: sessionId) }
        }
        defer {
            if replacesPooledTransport {
                MetadataConnectionPool.shared.endTransportReplacement(connectionId: sessionId)
            }
        }
        defer {
            if replacesPooledTransport {
                RoutineDebugSessions.shared.reopenAdmission(for: sessionId)
            }
        }

        do {
            // Re-fetched: the local copy may hold a driver something replaced meanwhile.
            activeSessions[sessionId]?.driver?.disconnect()

            var passwordOverride = activeSessions[sessionId]?.cachedPassword
            if ConnectionCredentialResolver.promptsForPassword(session.connection),
               !pluginManager.hidesPassword(for: session.connection),
               passwordOverride == nil
            {
                let isApiOnly = pluginManager.connectionMode(for: session.connection.type) == .apiOnly
                guard let prompted = await PasswordPromptHelper.prompt(
                    connectionName: session.connection.name,
                    isAPIToken: isApiOnly,
                    window: NSApp.keyWindow
                ) else {
                    throw CancellationError()
                }
                passwordOverride = prompted
            }
            try requireCurrentAttempt(generation, for: sessionId)

            let preparedConfiguration = try await DatabaseDriverFactory.prepareConfiguration(for: session.connection)
            let deadline = ConnectionDeadline(configuredSeconds: session.connection.connectTimeoutSeconds)
            let effectiveConnection = try await buildEffectiveConnection(
                for: session.connection,
                deadline: deadline,
                ownsAttempt: { self.isCurrentAttempt(generation, for: sessionId) }
            )
            try requireCurrentAttempt(generation, for: sessionId)

            // Nil means the user declined the re-prompt after an auth failure: a cancellation, not a refusal.
            guard let connectResult = try await connectReconnectDriver(
                for: session,
                effectiveConnection: effectiveConnection,
                passwordOverride: passwordOverride,
                allowsCredentialPrompt: true,
                deadline: deadline,
                preparedConfiguration: preparedConfiguration,
                ownsAttempt: { self.isCurrentAttempt(generation, for: sessionId) }
            ) else {
                throw CancellationError()
            }
            let driver = connectResult.driver

            let startupFailures = await applyTimeoutAndStartupCommands(
                on: driver,
                queryTimeoutSeconds: session.effectiveQueryTimeoutSeconds,
                startupCommands: session.connection.startupCommands,
                connectionName: session.connection.name
            )
            let restoreWarning = await restoreSchemaAndDatabase(
                on: driver,
                savedSchema: activeSessions[sessionId]?.browseSchema,
                savedDatabase: databaseSwitchRequiresReconnect(session.connection) ? nil : activeSessions[sessionId]?.browseDatabase
            )
            guard isCurrentAttempt(generation, for: sessionId) else {
                driver.disconnect()
                throw CancellationError()
            }

            let warning = openingWarning(
                driver: driver, startupFailures: startupFailures, restoreWarning: restoreWarning, for: sessionId
            )
            updateSession(sessionId) { session in
                session.driver = driver
                session.status = .connected
                session.effectiveConnection = effectiveConnection
                session.connectionWarning = warning
                if let schemaDriver = driver as? SchemaSwitchable {
                    session.browseSchema = schemaDriver.currentSchema
                }
                if let cachedPassword = connectResult.cachedPassword,
                   !session.connection.usesIAMToken
                {
                    session.cachedPassword = cachedPassword
                }
            }
            markSessionLive(sessionId)

            await startHealthMonitor(for: sessionId)

            AppEvents.shared.databaseDidConnect.send(DatabaseDidConnect(connectionId: sessionId))

            Self.logger.info("Manual reconnect succeeded for: \(session.connection.name)")
        } catch {
            // A newer connect owns the session now; its outcome is the one to report.
            guard isCurrentAttempt(generation, for: sessionId) else { throw error }
            // A declined prompt, or a cancellation the driver raised, lands on .disconnected, never a spinner with no exit.
            guard !DatabaseCancellationDiagnosis.isCancellation(error) else {
                updateSession(sessionId) { $0.status = .disconnected }
                markSessionUnreachable(sessionId, startedWith: attemptedDriver, info: Self.declinedReconnectInfo)
                throw error
            }
            Self.logger.error("Manual reconnect failed: \(error.publicLogShape, privacy: .public)")
            let message = String(format: String(localized: "Reconnect failed: %@"), error.localizedDescription)
            updateSession(sessionId) { session in
                session.status = .error(message)
                session.clearCachedData()
            }
            markSessionUnreachable(
                sessionId,
                startedWith: attemptedDriver,
                info: ConnectionFailureInfo(message: message)
            )
            throw error
        }
    }

    internal func connectReconnectDriver(
        for session: ConnectionSession,
        effectiveConnection: DatabaseConnection,
        passwordOverride initialPasswordOverride: String?,
        allowsCredentialPrompt: Bool,
        deadline initialDeadline: ConnectionDeadline,
        preparedConfiguration initialPreparedConfiguration: DatabaseDriverFactory.PreparedDriverConfiguration,
        ownsAttempt: () -> Bool
    ) async throws -> (driver: DatabaseDriver, cachedPassword: String?)? {
        var passwordOverride = initialPasswordOverride
        var deadline = initialDeadline
        let preparedConfiguration = initialPreparedConfiguration
        let timeoutEndpoint = ConnectionTimeoutEndpoint.database(session.connection.timeoutEndpointName)

        while true {
            var driver: DatabaseDriver?
            do {
                let candidate = try await DatabaseDriverFactory.createDriver(
                    for: effectiveConnection,
                    passwordOverride: passwordOverride,
                    awaitPlugins: true,
                    deadline: deadline,
                    timeoutEndpoint: timeoutEndpoint,
                    effectiveQueryTimeoutSeconds: session.effectiveQueryTimeoutSeconds,
                    preparedConfiguration: preparedConfiguration
                )
                driver = candidate
                try await candidate.connect()
                return (candidate, passwordOverride)
            } catch {
                driver?.disconnect()
                let reportedError = await Self.preferredTunnelFailure(replacing: error) {
                    await self.attributedTunnelFailure(for: session.connection)
                }

                switch await reconnectCredentialResolution(
                    for: session,
                    error: reportedError,
                    currentPassword: passwordOverride,
                    allowsCredentialPrompt: allowsCredentialPrompt
                ) {
                case .retry(let newPassword):
                    passwordOverride = newPassword
                    deadline = ConnectionDeadline(configuredSeconds: session.connection.connectTimeoutSeconds)
                case .abort:
                    await closeReconnectTunnels(for: session.connection, ownsAttempt: ownsAttempt)
                    return nil
                case .fail:
                    await closeReconnectTunnels(for: session.connection, ownsAttempt: ownsAttempt)
                    throw reportedError
                }
            }
        }
    }

    internal func reconnectCredentialResolution(
        for session: ConnectionSession,
        error: Error,
        currentPassword: String?,
        allowsCredentialPrompt: Bool = true,
        prompt: @escaping @MainActor (_ connectionName: String, _ isAPIToken: Bool, _ window: NSWindow?) async -> String? = PasswordPromptHelper.prompt
    ) async -> ReconnectCredentialResolution {
        // An unattended reconnect never asks.
        guard allowsCredentialPrompt else { return .fail }
        guard ConnectionCredentialResolver.promptsForPassword(session.connection),
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

    // A superseded attempt leaves the slot alone: the tunnel under this connection's id is the newer attempt's.
    private func closeReconnectTunnels(for connection: DatabaseConnection, ownsAttempt: () -> Bool) async {
        guard ownsAttempt(), let tunnelManager = activeTunnelManager(for: connection) else { return }
        do {
            try await tunnelManager.closeTunnel(connectionId: connection.id)
        } catch {
            Self.logger.warning("Failed to close tunnel during reconnect: \(error.localizedDescription)")
        }
    }
}
