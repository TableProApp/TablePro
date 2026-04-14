//
//  DatabaseManager+SSH.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation
import os
import TableProPluginKit

// MARK: - SSH Tunnel Helper

extension DatabaseManager {
    /// Build an effective connection for the given database connection.
    /// If SSH tunneling is enabled, creates a tunnel and returns a modified connection
    /// pointing at localhost with the tunnel port. Otherwise returns the original connection.
    ///
    /// - Parameters:
    ///   - connection: The original database connection configuration.
    ///   - sshPasswordOverride: Optional SSH password to use instead of the stored one (for test connections).
    /// - Returns: A connection suitable for the database driver (SSH disabled, pointing at tunnel if applicable).
    internal func buildEffectiveConnection(
        for connection: DatabaseConnection,
        sshPasswordOverride: String? = nil
    ) async throws -> DatabaseConnection {
        let sshConfig = connection.resolvedSSHConfig
        guard sshConfig.enabled else { return connection }

        let storedSshPassword: String?
        let keyPassphrase: String?
        let totpSecret: String?

        switch connection.sshTunnelMode {
        case .disabled:
            return connection
        case .profile(let profileId, _):
            storedSshPassword = SSHProfileStorage.shared.loadSSHPassword(for: profileId)
            keyPassphrase = SSHProfileStorage.shared.loadKeyPassphrase(for: profileId)
            totpSecret = SSHProfileStorage.shared.loadTOTPSecret(for: profileId)
        case .inline:
            storedSshPassword = ConnectionStorage.shared.loadSSHPassword(for: connection.id)
            keyPassphrase = ConnectionStorage.shared.loadKeyPassphrase(for: connection.id)
            totpSecret = ConnectionStorage.shared.loadTOTPSecret(for: connection.id)
        }

        let sshPassword = sshPasswordOverride ?? storedSshPassword

        let tunnelPort = try await SSHTunnelManager.shared.createTunnel(
            connectionId: connection.id,
            sshHost: sshConfig.host,
            sshPort: sshConfig.port,
            sshUsername: sshConfig.username,
            authMethod: sshConfig.authMethod,
            privateKeyPath: sshConfig.privateKeyPath,
            keyPassphrase: keyPassphrase,
            sshPassword: sshPassword,
            agentSocketPath: sshConfig.agentSocketPath,
            remoteHost: connection.host,
            remotePort: connection.port,
            jumpHosts: sshConfig.jumpHosts,
            totpMode: sshConfig.totpMode,
            totpSecret: totpSecret,
            totpAlgorithm: sshConfig.totpAlgorithm,
            totpDigits: sshConfig.totpDigits,
            totpPeriod: sshConfig.totpPeriod
        )

        // Adapt SSL config for tunnel: SSH already authenticates the server,
        // remote environment and aren't readable locally, so strip them and
        // use at least .preferred so libpq negotiates SSL when the server
        // requires it (SSH already authenticates the server itself).
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

        return DatabaseConnection(
            id: connection.id,
            name: connection.name,
            host: "127.0.0.1",
            port: tunnelPort,
            database: connection.database,
            username: connection.username,
            type: connection.type,
            sshConfig: SSHConfiguration(),
            sslConfig: tunnelSSL,
            additionalFields: effectiveFields
        )
    }

    // MARK: - SSH Tunnel Recovery

    /// Handle SSH tunnel death by attempting reconnection with exponential backoff.
    /// Guarded by `recoveringConnectionIds` to prevent duplicate concurrent recovery
    /// when both the keepalive death callback and the wake-from-sleep handler fire
    /// for the same connection.
    func handleSSHTunnelDied(connectionId: UUID) async {
        guard let session = activeSessions[connectionId],
              !recoveringConnectionIds.contains(connectionId) else { return }

        recoveringConnectionIds.insert(connectionId)
        defer { recoveringConnectionIds.remove(connectionId) }

        Self.logger.warning("SSH tunnel died for connection: \(session.connection.name)")

        // Stop health monitor before retrying to prevent stale pings during reconnect
        await stopHealthMonitor(for: connectionId)

        // Disconnect the stale driver and invalidate it so connectToSession
        // creates a fresh connection instead of short-circuiting on driver != nil
        activeSessions[connectionId]?.driver?.disconnect()
        updateSession(connectionId) { session in
            session.driver = nil
            session.status = .connecting
        }

        let maxRetries = 10
        for retryCount in 0..<maxRetries {
            let delay = ExponentialBackoff.delay(for: retryCount + 1, maxDelay: 120)
            Self.logger.info("SSH reconnect attempt \(retryCount + 1)/\(maxRetries) in \(delay)s for: \(session.connection.name)")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            do {
                try await connectToSession(session.connection)
                Self.logger.info("Successfully reconnected SSH tunnel for: \(session.connection.name)")
                return
            } catch {
                Self.logger.warning("SSH reconnect attempt \(retryCount + 1) failed: \(error.localizedDescription)")
            }
        }

        Self.logger.error("All SSH reconnect attempts failed for: \(session.connection.name)")

        // Mark as error and release stale cached data
        updateSession(connectionId) { session in
            session.status = .error("SSH tunnel disconnected. Click to reconnect.")
            session.clearCachedData()
        }
    }
}
