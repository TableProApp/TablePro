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
        if activeSessions[connection.id]?.driver != nil { return }
        try await ensureConnectedDedup.execute(key: connection.id) {
            try await self.connectToSession(
                connection,
                passwordOverride: passwordOverride,
                sshPasswordOverride: sshPasswordOverride
            )
        }
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
            if currentSessionId == connectionId {
                currentSessionId = nil
            }
        }
    }
}
