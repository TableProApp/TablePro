//
//  DatabaseManager+Tunnel.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

// MARK: - Shared Tunnel Helpers

extension DatabaseManager {
    /// Rewrite a connection to point at the local tunnel endpoint. A 127.0.0.1
    /// certificate can't satisfy hostname verification, so verify modes drop to
    /// `.required` while keeping encryption; cert paths are cleared and the pre-tunnel
    /// endpoint is recorded for the callers that must name the real server rather than
    /// the local forward. A tunnel forwards a single local port, so MongoDB's
    /// seed list is collapsed to that endpoint and a direct connection is forced,
    /// stopping replica set discovery from reaching members behind the tunnel.
    /// Shared by the SSH and Cloudflare tunnel paths.
    ///
    /// A server listening on a Unix socket answers every TLS request with a refusal, because
    /// it decides from its own listening socket family and never consults `pg_hba`. Encryption
    /// modes are therefore dropped for a socket forward, which costs nothing: the whole path
    /// already runs inside the SSH transport.
    func tunneledConnection(
        from connection: DatabaseConnection,
        localPort: Int,
        forwardsToUnixSocket: Bool = false
    ) -> DatabaseConnection {
        var tunnelSSL = connection.sslConfig
        if forwardsToUnixSocket {
            if tunnelSSL.isEnabled {
                Self.logger.notice("Socket forward: disabling TLS, the destination cannot negotiate it")
            }
            tunnelSSL.mode = .disabled
            tunnelSSL.caCertificatePath = ""
            tunnelSSL.clientCertificatePath = ""
            tunnelSSL.clientKeyPath = ""
        } else if tunnelSSL.isEnabled {
            if tunnelSSL.verifiesCertificate {
                tunnelSSL.mode = .required
            }
            tunnelSSL.caCertificatePath = ""
            tunnelSSL.clientCertificatePath = ""
            tunnelSSL.clientKeyPath = ""
        }

        var effectiveFields = connection.additionalFields
        effectiveFields[DatabaseConnection.sshForwardUnixSocketPathKey] = nil
        let forwardEndpoint = connection.tunnelForwardEndpoint
        effectiveFields[DatabaseConnection.preTunnelHostKey] = forwardEndpoint.host
        effectiveFields[DatabaseConnection.preTunnelPortKey] = String(forwardEndpoint.port)
        /// A host list names the servers the driver would reach for itself, and behind a tunnel
        /// there is one forwarded endpoint instead, so the list has to go. An SRV connection is
        /// the exception: its host is a lookup name rather than a server to dial, the driver
        /// resolves it and then connects through the forward anyway, and clearing it leaves the
        /// driver with nothing to resolve. The rule used to live in the MongoDB branch below,
        /// where the `!usesMongoSrv` guard protected it; generalising the clear to every host-list
        /// field moved it above that guard and dropped the exception with it.
        if !connection.usesMongoSrv {
            for fieldId in connection.hostListFieldIds {
                effectiveFields[fieldId] = nil
            }
        }
        if connection.type.pluginTypeId == "MongoDB", !connection.usesMongoSrv {
            effectiveFields["mongoParam_directConnection"] = "true"
        }
        if connection.type.pluginTypeId == "Redis" {
            effectiveFields["redisMode"] = "standalone"
        }
        /// Kafka's Metadata reply names every broker by its ADVERTISED address, and a client is
        /// expected to dial those directly for the partitions they lead. Behind a tunnel there
        /// is one forwarded port, so an advertised `broker-2.internal:9092` is unreachable and
        /// the fetch hangs until it times out. Pinning the driver to the bootstrap endpoint is
        /// the same move MongoDB and Redis get above, for the same reason.
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
        case .none: return nil
        }
    }

    /// The SSH-layer reason a tunneled connect failed, when the tunnel recorded one. The driver
    /// only ever sees a local socket that was accepted and then stayed silent, so its own error
    /// names a read timeout and never the cause. Read before the tunnel is torn down.
    func attributedTunnelFailure(for connection: DatabaseConnection) async -> SSHTunnelError? {
        guard let manager = activeTunnelManager(for: connection) as? SSHTunnelManager else { return nil }
        return await manager.consumeLastForwardFailure(connectionId: connection.id)
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
                try await connectToSession(session.connection)
                Self.logger.info("Successfully reconnected \(kind, privacy: .public) tunnel for: \(session.connection.name)")
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
            ConnectionFailureInfo(
                message: disconnectedMessage,
                failureReason: String(
                    format: String(localized: "Reconnecting failed after %d attempts."),
                    attempts
                ),
                recoverySuggestion: String(localized: "Check the tunnel host and your network, then try again.")
            ),
            for: connectionId
        )
        finalizeConnectionFailure(for: connectionId, cancelled: false)
    }
}
