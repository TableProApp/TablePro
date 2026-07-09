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
    /// `.required` while keeping encryption; cert paths are cleared and pgpass keeps
    /// the original host/port. A tunnel forwards a single local port, so MongoDB's
    /// seed list is collapsed to that endpoint and a direct connection is forced,
    /// stopping replica set discovery from reaching members behind the tunnel.
    /// Shared by the SSH and Cloudflare tunnel paths.
    func tunneledConnection(from connection: DatabaseConnection, localPort: Int) -> DatabaseConnection {
        var tunnelSSL = connection.sslConfig
        if tunnelSSL.isEnabled {
            if tunnelSSL.verifiesCertificate {
                tunnelSSL.mode = .required
            }
            tunnelSSL.caCertificatePath = ""
            tunnelSSL.clientCertificatePath = ""
            tunnelSSL.clientKeyPath = ""
        }

        var effectiveFields = connection.additionalFields
        if connection.usePgpass {
            effectiveFields["pgpassOriginalHost"] = connection.host
            effectiveFields["pgpassOriginalPort"] = String(connection.port)
        }
        if connection.type.pluginTypeId == "MongoDB", !connection.usesMongoSrv {
            effectiveFields["mongoHosts"] = nil
            effectiveFields["mongoParam_directConnection"] = "true"
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
        case .none: return nil
        }
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

        updateSession(connectionId) { session in
            session.status = .error(disconnectedMessage)
            session.clearCachedData()
        }
    }
}
