//
//  DatabaseManager+EnsureConnected.swift
//  TablePro
//

import Foundation
import os

extension DatabaseManager {
    func ensureConnected(
        _ connection: DatabaseConnection,
        passwordOverride: String? = nil,
        sshPasswordOverride: String? = nil
    ) async throws {
        /// An installed driver is only a reason to skip while it still answers. A reconnect that
        /// gave up leaves one behind, and returning here made Reconnect a button that did nothing
        /// on the one connection that needed it.
        if let session = activeSessions[connection.id], session.driver != nil, session.liveness == .live {
            return
        }
        try await ensureConnectedDedup.execute(key: connection.id) {
            try await self.connectToSession(
                connection,
                passwordOverride: passwordOverride,
                sshPasswordOverride: sshPasswordOverride
            )
        }
    }

    func invalidateConnectionAttempt(_ connectionId: UUID) {
        connectionAttempts.invalidate(for: connectionId)
    }

    func cancelEnsureConnected(_ connectionId: UUID) async {
        connectionAttempts.invalidate(for: connectionId)
        await ensureConnectedDedup.cancel(key: connectionId)
        if let session = activeSessions[connectionId], session.driver == nil {
            if let tunnelManager = activeTunnelManager(for: session.connection) {
                do {
                    try await tunnelManager.closeTunnel(connectionId: connectionId)
                } catch {
                    Self.logger.warning("Tunnel cleanup failed for \(connectionId): \(error.localizedDescription)")
                }
            }
            removeSessionEntry(for: connectionId)
            if lastActiveSessionId == connectionId {
                lastActiveSessionId = nil
            }
        }
    }
}
