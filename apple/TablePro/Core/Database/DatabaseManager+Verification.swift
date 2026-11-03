//
//  DatabaseManager+Verification.swift
//  TablePro
//

import Combine
import Foundation
import os

// MARK: - On-demand connection verification

extension DatabaseManager {
    // One answer for the scheduled and the on-demand check: a file-backed engine has nothing to lose.
    internal func supportsHealthChecks(_ connectionId: UUID) -> Bool {
        guard let session = activeSessions[connectionId] else { return false }
        // Per connection, not per type: a remote SQLite session holds a socket that can drop.
        if session.connection.opensRemoteDatabaseSession { return true }
        return PluginMetadataRegistry.shared.snapshot(
            for: session.connection.type
        )?.supportsHealthMonitor ?? true
    }

    internal func markSessionVerified(_ connectionId: UUID, at date: Date = Date()) {
        guard activeSessions[connectionId] != nil else { return }
        lastVerifiedAt[connectionId] = date
    }

    internal func forgetVerification(for connectionId: UUID) {
        lastVerifiedAt.removeValue(forKey: connectionId)
    }

    // A Mac that slept comes back with sockets the server closed while nothing here observed the clock.
    internal func forgetAllVerifications() {
        lastVerifiedAt.removeAll()
    }

    // Replaces the poll when the user turns it down or off (#2700); free on the default setting.
    internal func verifyBeforeUse(_ connectionId: UUID) async {
        guard let session = activeSessions[connectionId], let driver = session.driver else { return }
        // A driver that reports its connection gone answered unasked, so an opted-out engine is reconnected too.
        guard supportsHealthChecks(connectionId) || driver.hasLostConnection else { return }
        // A session already in trouble has a reconnect of its own; checking again would race it.
        guard session.liveness == .live else { return }
        // A query already on this driver answers better than a ping, which would race it.
        guard queriesInFlight[connectionId] == nil else { return }
        // No record means ask; a driver that reported its connection lost voids its stamp.
        if let last = lastVerifiedAt[connectionId],
           ConnectionHealthCheck.isFresh(last),
           !driver.hasLostConnection {
            return
        }

        try? await verificationDedup.execute(key: connectionId) {
            await self.runVerification(connectionId, driver: driver)
        }
    }

    // An installed driver is not the question: a failed recovery leaves one disconnected.
    internal func isUsable(_ connectionId: UUID) -> Bool {
        guard let session = activeSessions[connectionId], session.driver != nil else { return false }
        switch session.liveness {
        case .live: return true
        // A loop redials because the driver stopped answering; without one, `.recovering` is a blip.
        case .recovering: return recoveryLoops[connectionId] == nil
        case .unreachable: return false
        }
    }

    // Only ever starts a monitor: a running one rereads the interval and ends itself when checks go off.
    internal func observeHealthCheckSetting() {
        healthCheckSettingCancellable = AppEvents.shared.connectionHealthCheckChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                let previous = self.healthMonitorRestart
                self.healthMonitorRestart = Task { @MainActor in
                    await previous?.value
                    await self.startMissingHealthMonitors()
                }
            }
    }

    private func startMissingHealthMonitors() async {
        guard AppSettingsManager.shared.general.connectionHealthCheck.interval != nil else { return }
        for connectionId in Array(activeSessions.keys) {
            guard healthMonitors[connectionId] == nil,
                  let session = activeSessions[connectionId],
                  session.driver != nil,
                  session.isConnected,
                  session.liveness == .live
            else { continue }
            await startHealthMonitor(for: connectionId)
        }
    }

    // Fenced on the checked driver and on no recovery having started or been cancelled meanwhile: a ping
    // blocked in a C call answers late, and its answer must not revive a session the user cancelled.
    private func runVerification(_ connectionId: UUID, driver: DatabaseDriver) async {
        do {
            // Counted as an operation, so the scheduled monitor's ping skips instead of entering the same driver.
            try await trackOperation(sessionId: connectionId) {
                try await driver.ping()
            }
            guard holdsUnrecoveredDriver(connectionId, driver) else { return }
            markSessionLive(connectionId)
        } catch {
            guard holdsUnrecoveredDriver(connectionId, driver) else { return }
            Self.logger.info("Connection \(connectionId) did not answer before use, reconnecting")
            // The session's loop makes the attempt and keeps redialing if it fails.
            _ = await performHealthMonitorReconnect(connectionId: connectionId, failedDriver: ObjectIdentifier(driver))
        }
    }

    private func holdsUnrecoveredDriver(_ connectionId: UUID, _ driver: DatabaseDriver) -> Bool {
        guard let session = activeSessions[connectionId], recoveryLoops[connectionId] == nil else { return false }
        return session.driver === driver && session.liveness == .live
    }
}
