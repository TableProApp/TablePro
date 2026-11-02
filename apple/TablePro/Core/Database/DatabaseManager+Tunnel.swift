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
    // A 127.0.0.1 certificate cannot satisfy hostname verification, so verify modes drop to `.required`.
    // A server on a Unix socket refuses every TLS request, so a socket forward drops encryption; SSH carries it.
    func tunneledConnection(
        from connection: DatabaseConnection,
        localPort: Int,
        forwardsToUnixSocket: Bool = false,
        securesTransport: Bool = false
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
        } else if connection.tunnelForwardUsesHTTPS {
            tunnelSSL.mode = .required
        }

        var effectiveFields = connection.additionalFields
        effectiveFields[DatabaseConnection.sshForwardUnixSocketPathKey] = nil
        // The MySQL driver dials this Mac's socket instead of the forwarded port when the key is set.
        effectiveFields[MySQLLocalSocket.fieldKey] = nil
        let forwardEndpoint = connection.tunnelForwardEndpoint
        effectiveFields[DatabaseConnection.preTunnelHostKey] = forwardEndpoint.host
        effectiveFields[DatabaseConnection.preTunnelPortKey] = String(forwardEndpoint.port)
        // An SSH forward to the server's own socket is encrypted the whole way, as the proxy's hop is.
        effectiveFields[DatabaseConnection.tunnelSecuresTransportKey] = securesTransport || forwardsToUnixSocket ? "true" : nil
        // Behind a tunnel there is one forwarded endpoint; an SRV host is a lookup name the driver still needs.
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
        // Kafka's advertised broker addresses are unreachable behind one forwarded port.
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

    // The driver only sees a silent local socket, so its error never names the cause. Read before teardown.
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

    // The driver and the session stay; the session's reconnect loop redials through a rebuilt tunnel.
    func recoverDeadTunnel(connectionId: UUID, kind: String, disconnectedMessage: String) {
        guard let session = activeSessions[connectionId] else { return }
        Self.logger.warning("\(kind, privacy: .public) tunnel died for connection: \(session.connection.name)")
        beginRecovery(for: connectionId, cause: .transportClosed(disconnectedMessage))
    }
}
