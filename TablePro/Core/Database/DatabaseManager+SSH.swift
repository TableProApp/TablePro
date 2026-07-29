//
//  DatabaseManager+SSH.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation

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
        let enabledKinds = connection.enabledTunnelKinds
        guard enabledKinds.count <= 1 else {
            throw ConnectionTunnelError.mutualExclusivityViolation(enabledKinds)
        }
        switch enabledKinds.first {
        case .cloudflare:
            return try await buildCloudflareEffectiveConnection(for: connection)
        case .cloudSQLProxy:
            return try await buildCloudSQLProxyEffectiveConnection(for: connection)
        case .socksProxy:
            return try await buildSOCKSProxyEffectiveConnection(for: connection)
        case .ssh, .none:
            break
        }

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
            storedSshPassword = connectionStorage.loadSSHPassword(for: connection.id)
            keyPassphrase = connectionStorage.loadKeyPassphrase(for: connection.id)
            totpSecret = connectionStorage.loadTOTPSecret(for: connection.id)
        }

        let sshPassword = sshPasswordOverride ?? storedSshPassword
        let destination = connection.sshForwardDestination

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
            destination: destination,
            jumpHosts: sshConfig.jumpHosts,
            totpMode: sshConfig.totpMode,
            totpSecret: totpSecret,
            totpAlgorithm: sshConfig.totpAlgorithm,
            totpDigits: sshConfig.totpDigits,
            totpPeriod: sshConfig.totpPeriod
        )

        return tunneledConnection(
            from: connection,
            localPort: tunnelPort,
            forwardsToUnixSocket: destination.isUnixSocket
        )
    }

    // MARK: - SSH Tunnel Recovery

    /// Handle SSH tunnel death by attempting reconnection with exponential backoff.
    /// Guarded by `recoveringConnectionIds` to prevent duplicate concurrent recovery
    /// when both the keepalive death callback and the wake-from-sleep handler fire
    /// for the same connection.
    func handleSSHTunnelDied(connectionId: UUID) async {
        await recoverDeadTunnel(
            connectionId: connectionId,
            kind: "SSH",
            disconnectedMessage: String(localized: "SSH tunnel disconnected. Click to reconnect.")
        )
    }
}
