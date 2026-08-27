//
//  DatabaseManager+Queries.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import os
import TableProPluginKit

// MARK: - Query Execution

extension DatabaseManager {
    /// Track an in-flight operation for the given session, preventing health monitor
    /// pings from racing on the same non-thread-safe driver connection.
    internal func trackOperation<T>(
        sessionId: UUID,
        operation: () async throws -> T
    ) async throws -> T {
        queriesInFlight[sessionId, default: 0] += 1
        if queriesInFlight[sessionId] == 1 {
            queryStartTimes[sessionId] = Date()
        }
        defer {
            if let count = queriesInFlight[sessionId], count > 1 {
                queriesInFlight[sessionId] = count - 1
            } else {
                queriesInFlight.removeValue(forKey: sessionId)
                queryStartTimes.removeValue(forKey: sessionId)
            }
        }
        return try await operation()
    }

    /// Test a connection without keeping it open
    func testConnection(
        _ connection: DatabaseConnection,
        sshPassword: String? = nil,
        passwordOverride: String? = nil
    ) async throws -> Bool {
        // A remote file answers the only question this button asks without moving the file.
        if connection.activeTunnelKind == .remoteFile {
            return try await testRemoteDatabaseFile(connection, sshPassword: sshPassword)
        }

        // Build effective connection (creates SSH tunnel if needed)
        let testConnection = try await buildEffectiveConnection(
            for: connection,
            sshPasswordOverride: sshPassword
        )

        // Detect whether buildEffectiveConnection created a tunnel by checking
        // if the returned connection was redirected to localhost (tunnel endpoint)
        let tunnelWasCreated = testConnection.host == "127.0.0.1" && testConnection.port != connection.port

        let result: Bool
        do {
            let driver = try await DatabaseDriverFactory.createDriver(
                for: testConnection,
                passwordOverride: passwordOverride,
                awaitPlugins: true
            )
            result = try await driver.testConnection()
        } catch {
            if tunnelWasCreated, let tunnelManager = activeTunnelManager(for: connection) {
                do {
                    try await tunnelManager.closeTunnel(connectionId: connection.id)
                } catch {
                    Self.logger.warning("Tunnel cleanup failed for \(connection.name): \(error.localizedDescription)")
                }
            }
            throw error
        }

        if tunnelWasCreated, let tunnelManager = activeTunnelManager(for: connection) {
            do {
                try await tunnelManager.closeTunnel(connectionId: connection.id)
            } catch {
                Self.logger.warning("Tunnel cleanup failed for \(connection.name): \(error.localizedDescription)")
            }
        }

        return result
    }
}
