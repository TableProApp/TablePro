//
//  DatabaseManager+EnsureConnected.swift
//  TablePro
//

import Foundation
import os

extension DatabaseManager {
    func ensureConnected(_ connection: DatabaseConnection) async throws {
        if activeSessions[connection.id]?.driver != nil { return }
        try await ensureConnectedDedup.execute(key: connection.id) {
            try await self.connectToSession(connection)
        }
    }

    func cancelEnsureConnected(_ connectionId: UUID) async {
        await ensureConnectedDedup.cancel(key: connectionId)
        if let session = activeSessions[connectionId], session.driver == nil {
            if session.connection.resolvedSSHConfig.enabled {
                do {
                    try await SSHTunnelManager.shared.closeTunnel(connectionId: connectionId)
                } catch {
                    Self.logger.warning("SSH tunnel cleanup failed for \(connectionId): \(error.localizedDescription)")
                }
            }
            removeSessionEntry(for: connectionId)
            if currentSessionId == connectionId {
                currentSessionId = nil
            }
        }
    }
}
