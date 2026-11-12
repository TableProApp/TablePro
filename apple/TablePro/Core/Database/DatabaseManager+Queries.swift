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
    ) async throws -> ConnectionTestResult {
        let timeoutEndpoint = ConnectionTimeoutEndpoint.database(connection.timeoutEndpointName)
        let queryTimeoutSeconds = ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(
            configuredSeconds: connection.queryTimeoutSeconds,
            globalSeconds: AppSettingsManager.shared.general.queryTimeoutSeconds
        )

        // A remote file answers the only question this button asks without moving the file.
        if connection.activeTunnelKind == .remoteFile {
            do {
                let reached = try await testRemoteDatabaseFile(
                    connection,
                    sshPassword: sshPassword,
                    deadline: ConnectionDeadline(configuredSeconds: connection.connectTimeoutSeconds)
                )
                return ConnectionTestResult(succeeded: reached)
            } catch {
                throw await diagnosedConnectFailure(error, for: connection)
            }
        }

        let dialled: DatabaseConnection
        do {
            dialled = try await resolvingRDSEndpointAlias(of: connection, trigger: .request)
        } catch {
            throw await diagnosedConnectFailure(error, for: connection)
        }
        let preparedConfiguration = try await DatabaseDriverFactory.prepareConfiguration(for: connection)
        let deadline = ConnectionDeadline(configuredSeconds: connection.connectTimeoutSeconds)

        let testConnection: DatabaseConnection
        do {
            testConnection = try await buildEffectiveConnection(
                for: dialled,
                sshPasswordOverride: sshPassword,
                deadline: deadline
            )
        } catch {
            throw await diagnosedConnectFailure(error, for: connection)
        }

        let tunnelManager = activeTunnelManager(for: connection)
        // The form tests under a throwaway id, so a role of the connection's own leases a user no connect reuses.
        defer {
            let owner = ConnectionCredentialResolver.credentialOwner(for: connection)
            if owner == connection.id, activeSessions[connection.id] == nil {
                VaultDatabaseCredentials.shared.endUse(connection: connection.id, live: Set(activeSessions.keys))
            }
        }

        let result: ConnectionTestResult
        do {
            let driver = try await DatabaseDriverFactory.createDriver(
                for: testConnection,
                passwordOverride: passwordOverride,
                awaitPlugins: true,
                deadline: deadline,
                timeoutEndpoint: timeoutEndpoint,
                effectiveQueryTimeoutSeconds: queryTimeoutSeconds,
                preparedConfiguration: preparedConfiguration
            )
            let succeeded = try await driver.testConnection()
            result = ConnectionTestResult(succeeded: succeeded, warning: driver.connectionWarning)
        } catch {
            let reportedError = await Self.preferredTunnelFailure(replacing: error) {
                await self.attributedTunnelFailure(for: connection)
            }
            if let tunnelManager {
                do {
                    try await tunnelManager.closeTunnel(connectionId: connection.id)
                } catch {
                    Self.logger.warning("Tunnel cleanup failed for \(connection.name): \(error.localizedDescription)")
                }
            }
            throw await diagnosedConnectFailure(reportedError, for: connection)
        }

        if let tunnelManager {
            do {
                try await tunnelManager.closeTunnel(connectionId: connection.id)
            } catch {
                Self.logger.warning("Tunnel cleanup failed for \(connection.name): \(error.localizedDescription)")
            }
        }

        return result
    }
}
