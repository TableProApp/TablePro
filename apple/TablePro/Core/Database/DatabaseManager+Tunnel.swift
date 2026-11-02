//
//  DatabaseManager+Tunnel.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProRedisCore
import TableProSSHConfig
import TableProUtilities

// MARK: - Shared Tunnel Helpers

extension DatabaseManager {
    // The pre-tunnel endpoint names the server behind the forward, for the certificate check, pgpass and IAM signing.
    // MongoDB's seed list collapses to the one forwarded port with a direct connection, so replica set discovery
    // never reaches members behind the tunnel.
    func tunneledConnection(
        from connection: DatabaseConnection,
        localPort: Int,
        forwardsToUnixSocket: Bool = false,
        securesTransport: Bool = false
    ) -> DatabaseConnection {
        let listenerSecuresTransport = securesTransport || forwardsToUnixSocket
        if listenerSecuresTransport, connection.sslConfig.isEnabled {
            Self.logger.notice("Tunnel listener secures the hop itself: disabling TLS to it")
        }
        let tunnelSSL = connection.sslConfigurationThroughTunnel(listenerSecuresTransport: listenerSecuresTransport)

        var effectiveFields = connection.additionalFields
        effectiveFields[DatabaseConnection.sshForwardUnixSocketPathKey] = nil
        // The MySQL driver dials this Mac's socket instead of the forwarded port when the key is set.
        effectiveFields[MySQLLocalSocket.fieldKey] = nil
        let forwardEndpoint = connection.tunnelForwardEndpoint
        effectiveFields[DatabaseConnection.preTunnelHostKey] = forwardEndpoint.host
        effectiveFields[DatabaseConnection.preTunnelPortKey] = String(forwardEndpoint.port)
        // An SSH forward to the server's own socket is encrypted the whole way, as the proxy's hop is.
        effectiveFields[DatabaseConnection.tunnelSecuresTransportKey] = listenerSecuresTransport ? "true" : nil
        // One forwarded port replaces the host list. An SRV host is a name the driver resolves, not a server to dial.
        if !connection.usesMongoSrv {
            for fieldId in connection.hostListFieldIds {
                effectiveFields[fieldId] = nil
            }
        }
        if connection.type.pluginTypeId == "MongoDB", !connection.usesMongoSrv {
            // The driver reads option keys without case, so an imported `directconnection=false` would still apply.
            for key in effectiveFields.keys where key.lowercased() == "mongoparam_directconnection" {
                effectiveFields[key] = nil
            }
            effectiveFields["mongoParam_directConnection"] = "true"
        }
        if connection.type.pluginTypeId == "Redis" {
            effectiveFields[RedisDatabaseIndex.fieldName] = String(connection.redisDatabaseIndex)
            effectiveFields["redisMode"] = "standalone"
        }
        // Kafka's metadata names brokers by their advertised addresses, which the one forwarded port cannot reach.
        if connection.type.pluginTypeId == "Kafka" {
            effectiveFields["kafkaBrokerRouting"] = "bootstrapOnly"
        }

        return DatabaseConnection(
            id: connection.id,
            name: connection.name,
            host: "127.0.0.1",
            port: localPort,
            database: connection.database,
            username: connection.username,
            type: connection.type,
            sshConfig: SSHConfiguration(),
            sslConfig: tunnelSSL,
            passwordSource: connection.passwordSource,
            additionalFields: effectiveFields
        )
    }

    func activeTunnelManager(for connection: DatabaseConnection) -> (any TunnelManaging)? {
        switch connection.activeTunnelKind {
        case .ssh: return SSHTunnelManager.shared
        case .cloudflare: return CloudflareTunnelManager.shared
        case .cloudSQLProxy: return CloudSQLProxyManager.shared
        case .socksProxy: return SOCKSProxyManager.shared
        case .tunnelCommand: return TunnelCommandManager.shared
        case .remoteFile: return RemoteFileTransportManager.shared
        case .remoteDatabaseSession: return RemoteSQLiteTransportManager.shared
        case .none: return nil
        }
    }

    /// The transport-layer reason a tunneled connect failed, when the tunnel recorded one. The driver
    /// only ever sees a local socket that was accepted and then stayed silent, so its own error
    /// names a read timeout and never the cause. Read before the tunnel is torn down.
    func attributedTunnelFailure(for connection: DatabaseConnection) async -> (any Error)? {
        if let manager = activeTunnelManager(for: connection) as? SSHTunnelManager {
            return await manager.consumeLastForwardFailure(connectionId: connection.id)
        }
        if let manager = activeTunnelManager(for: connection) as? SOCKSProxyManager {
            return await manager.consumeLastConnectionFailure(connectionId: connection.id)
        }
        if let manager = activeTunnelManager(for: connection) as? RemoteSQLiteTransportManager {
            return await manager.consumeLastConnectionFailure(connectionId: connection.id)
        }
        return nil
    }

    static func preferredTunnelFailure(
        replacing error: any Error,
        attributedFailure: () async -> (any Error)?
    ) async -> any Error {
        guard !Task.isCancelled, !DatabaseCancellationDiagnosis.isCancellation(error) else { return error }
        return await attributedFailure() ?? error
    }

    func closeActiveTunnel(for connection: DatabaseConnection) {
        guard let manager = activeTunnelManager(for: connection) else { return }
        let connectionId = connection.id
        let connectionName = connection.name
        Task {
            do {
                try await manager.closeTunnel(connectionId: connectionId)
            } catch {
                Self.logger.warning("Tunnel cleanup failed for \(connectionName): \(error.localizedDescription)")
            }
        }
    }

    func hasActiveTunnel(for connection: DatabaseConnection) async -> Bool {
        guard let manager = activeTunnelManager(for: connection) else { return false }
        return await manager.hasTunnel(connectionId: connection.id)
    }

    /// Reconnect a session whose tunnel died, with exponential backoff. Guarded by
    /// `recoveringConnectionIds` so the keepalive death callback and the wake-from-sleep
    /// handler don't recover the same connection twice. Shared by both tunnel types.
    func recoverDeadTunnel(connectionId: UUID, kind: String, disconnectedMessage: String) async {
        guard let session = activeSessions[connectionId],
              !recoveringConnectionIds.contains(connectionId) else { return }

        recoveringConnectionIds.insert(connectionId)
        defer { recoveringConnectionIds.remove(connectionId) }

        Self.logger.warning("\(kind, privacy: .public) tunnel died for connection: \(session.connection.name)")

        await stopHealthMonitor(for: connectionId)

        await sessionLanes.closeAllNotingLostTransactions(for: connectionId)
        activeSessions[connectionId]?.driver?.disconnect()
        updateSession(connectionId) { session in
            session.driver = nil
            session.status = .connecting
        }

        let maxRetries = 10
        for retryCount in 0..<maxRetries {
            let delay = ExponentialBackoff.delay(for: retryCount + 1, maxDelay: 120)
            Self.logger.info("\(kind, privacy: .public) reconnect attempt \(retryCount + 1)/\(maxRetries) in \(delay)s for: \(session.connection.name)")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            do {
                // An edit saved while the tunnel was down is what the person expects the reconnect to dial.
                let current = connectionStorage.loadConnection(id: connectionId) ?? session.connection
                try await connectToSession(current, trigger: .background)
                Self.logger.info("Successfully reconnected \(kind, privacy: .public) tunnel for: \(session.connection.name)")
                return
            } catch is PreConnectScriptConsentError, is EnvVarReferenceConsentError, is LocalCredentialConsentError {
                // The refusal is already the session's recorded reason, and a retry gets the same one.
                return
            } catch {
                Self.logger.warning("\(kind, privacy: .public) reconnect attempt \(retryCount + 1) failed: \(error.localizedDescription)")
            }
        }

        Self.logger.error("All \(kind, privacy: .public) reconnect attempts failed for: \(session.connection.name)")

        failTunnelRecovery(
            connectionId: connectionId,
            disconnectedMessage: disconnectedMessage,
            attempts: maxRetries
        )
    }

    /// Leaving the session entry in place kept `exists == true, hasDriver == nil`, which every
    /// window reads as "still dialing", so an exhausted recovery painted a spinner that never
    /// ended. The entry has to go, and the reason has to outlive it so the window can say why.
    internal func failTunnelRecovery(connectionId: UUID, disconnectedMessage: String, attempts: Int) {
        recordDisconnectReason(
            .sessionLost(ConnectionFailureInfo(
                message: disconnectedMessage,
                failureReason: String(
                    format: String(localized: "Reconnecting failed after %d attempts."),
                    attempts
                ),
                recoverySuggestion: String(localized: "Check the tunnel host and your network, then try again.")
            )),
            for: connectionId
        )
        finalizeConnectionFailure(for: connectionId, cancelled: false)
    }
}
