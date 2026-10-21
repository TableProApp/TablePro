//
//  DatabaseManager+CredentialLease.swift
//  TablePro
//

import Combine
import Foundation
import os

extension DatabaseManager {
    enum CredentialLeaseAction: Equatable {
        case reconnectSession
        case closeLane(database: String)
        case none
    }

    internal func observeCredentialLeases() {
        credentialLeaseCancellable = AppEvents.shared.credentialLeaseEnding
            .receive(on: RunLoop.main)
            .sink { [weak self] ending in
                Task { await self?.credentialLeaseEnding(ending) }
            }
    }

    // A pooled driver needs nothing here: its `hasLostConnection` turns true, so the pool opens a fresh one.
    internal func credentialLeaseAction(for ending: CredentialLeaseEnding) -> CredentialLeaseAction {
        guard let session = activeSessions[ending.connectionId] else { return .none }
        if let driver = session.driver, ObjectIdentifier(driver) == ending.driver {
            return .reconnectSession
        }
        for database in sessionLanes.parkedDatabases(for: ending.connectionId) {
            if let parked = sessionLanes.parkedDriver(for: ending.connectionId, database: database),
               ObjectIdentifier(parked) == ending.driver {
                return .closeLane(database: database)
            }
        }
        return .none
    }

    internal func credentialLeaseEnding(_ ending: CredentialLeaseEnding) async {
        switch credentialLeaseAction(for: ending) {
        case .reconnectSession:
            await renewSessionCredentials(ending)
        case .closeLane(let database):
            await closeLane(database, for: ending)
        case .none:
            break
        }
    }

    // The lane reopens on its next use, signing in with a new lease. A transaction it held is reported as lost.
    private func closeLane(_ database: String, for ending: CredentialLeaseEnding) async {
        let connectionId = ending.connectionId
        guard let driver = sessionLanes.parkedDriver(for: connectionId, database: database) else { return }
        let held = await driver.heldSessionTransactionState()
        guard credentialLeaseAction(for: ending) == .closeLane(database: database) else { return }
        if !held.permitsAppTransaction {
            sessionLanes.markTransactionLost(database: database, for: connectionId)
        }
        Self.logger.info("Closing a lane whose Vault lease is ending for \(connectionId, privacy: .public)")
        sessionLanes.close(database: database, for: connectionId, supersedingOpens: false)
    }

    // Lets an open transaction finish while the user still exists, then signs in again through the unattended
    // reconnect, which is fenced on this driver and never prompts. The browsed turn is held throughout, so no
    // statement starts on the driver being replaced.
    private func renewSessionCredentials(_ ending: CredentialLeaseEnding) async {
        let connectionId = ending.connectionId
        let waitLimit = ContinuousClock.now + ending.remaining * 3 / 4
        while isBusy(connectionId, driver: ending.driver), ContinuousClock.now < waitLimit {
            try? await Task.sleep(for: .seconds(1))
        }
        guard credentialLeaseAction(for: ending) == .reconnectSession else { return }
        try? await sessionDriverGate.withExclusiveAccess(browsedGateKey(for: connectionId)) {
            guard credentialLeaseAction(for: ending) == .reconnectSession else { return }
            if holdsTransaction(connectionId, driver: ending.driver) {
                // Reported to the next statement on this database, as a lane's lost transaction is.
                let database = activeSessions[connectionId]?.resolvedBrowseDatabase ?? ""
                sessionLanes.markTransactionLost(database: database, for: connectionId)
            }
            Self.logger.info("Vault lease ending, reconnecting \(connectionId, privacy: .public) with a new one")
            let outcome = await performHealthMonitorReconnect(connectionId: connectionId, failedDriver: ending.driver)
            guard case .retry = outcome, credentialLeaseAction(for: ending) == .reconnectSession else { return }
            // Vault or the server did not answer. The monitor's next check retries; without one, the next use does.
            if healthMonitors[connectionId] != nil {
                markSessionRecovering(connectionId)
            } else {
                lastVerifiedAt[connectionId] = nil
            }
        }
    }

    private func isBusy(_ connectionId: UUID, driver: ObjectIdentifier) -> Bool {
        queriesInFlight[connectionId] != nil || holdsTransaction(connectionId, driver: driver)
    }

    private func holdsTransaction(_ connectionId: UUID, driver: ObjectIdentifier) -> Bool {
        sessionTransactions.holds(for: connectionId).contains { hold in
            sessionTransactions.driver(for: hold).map { ObjectIdentifier($0) == driver } ?? false
        }
    }
}
