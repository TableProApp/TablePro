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
}
