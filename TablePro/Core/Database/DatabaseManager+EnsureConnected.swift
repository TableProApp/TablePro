//
//  DatabaseManager+EnsureConnected.swift
//  TablePro
//

import Foundation

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
            removeSessionEntry(for: connectionId)
            if currentSessionId == connectionId {
                currentSessionId = nil
            }
        }
    }
}
