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

    /// Execute a query on the current session
    func execute(query: String) async throws -> QueryResult {
        guard let sessionId = currentSessionId, let driver = activeDriver else {
            throw DatabaseError.notConnected
        }

        return try await trackOperation(sessionId: sessionId) {
            try await driver.execute(query: query)
        }
    }

    /// Fetch tables from the current session
    func fetchTables() async throws -> [TableInfo] {
        guard let sessionId = currentSessionId, let driver = activeDriver else {
            throw DatabaseError.notConnected
        }

        return try await trackOperation(sessionId: sessionId) {
            try await driver.fetchTables()
        }
    }

    /// Fetch columns for a table from the current session
    func fetchColumns(table: String) async throws -> [ColumnInfo] {
        guard let sessionId = currentSessionId, let driver = activeDriver else {
            throw DatabaseError.notConnected
        }

        return try await trackOperation(sessionId: sessionId) {
            try await driver.fetchColumns(table: table)
        }
    }

    /// Test a connection without keeping it open
    func testConnection(
        _ connection: DatabaseConnection,
        sshPassword: String? = nil,
        passwordOverride: String? = nil
    ) async throws -> Bool {
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
            if tunnelWasCreated {
                do {
                    try await SSHTunnelManager.shared.closeTunnel(connectionId: connection.id)
                } catch {
                    Self.logger.warning("SSH tunnel cleanup failed for \(connection.name): \(error.localizedDescription)")
                }
            }
            throw error
        }

        if tunnelWasCreated {
            do {
                try await SSHTunnelManager.shared.closeTunnel(connectionId: connection.id)
            } catch {
                Self.logger.warning("SSH tunnel cleanup failed for \(connection.name): \(error.localizedDescription)")
            }
        }

        return result
    }
}
