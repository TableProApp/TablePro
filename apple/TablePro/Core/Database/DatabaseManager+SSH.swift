//
//  DatabaseManager+SSH.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation

import TableProSSHConfig
import TableProSSHTransport

// MARK: - SSH Tunnel Helper

extension DatabaseManager {
    // `ownsAttempt` is asked with nothing suspending before the tunnel is created: tunnels are keyed by
    // connection, and creating one closes whatever a newer attempt opened under the same id.
    internal func buildEffectiveConnection(
        for original: DatabaseConnection,
        sshPasswordOverride: String? = nil,
        deadline: ConnectionDeadline,
        ownsAttempt: () -> Bool = { true }
    ) async throws -> DatabaseConnection {
        var connection = SSHProfileStorage.shared.refreshingLinkedProfile(original)
        // Only the tunnel this connect opens says it secures the transport; a saved or imported field never does.
        connection.additionalFields[DatabaseConnection.tunnelSecuresTransportKey] = nil
        let enabledKinds = connection.enabledTunnelKinds
        guard enabledKinds.count <= 1 else {
            throw ConnectionTunnelError.mutualExclusivityViolation(enabledKinds)
        }
        if let refusal = ConnectionTunnelError.refusal(for: connection) {
            throw refusal
        }
        if !enabledKinds.isEmpty, !ownsAttempt() {
            throw CancellationError()
        }
        switch enabledKinds.first {
        case .cloudflare:
            return try await buildCloudflareEffectiveConnection(for: connection, deadline: deadline)
        case .cloudSQLProxy:
            return try await buildCloudSQLProxyEffectiveConnection(for: connection, deadline: deadline)
        case .socksProxy:
            return try await buildSOCKSProxyEffectiveConnection(for: connection, deadline: deadline)
        case .tunnelCommand:
            return try await buildTunnelCommandEffectiveConnection(
                for: connection,
                deadline: deadline,
                ownsAttempt: ownsAttempt
            )
        case .remoteFile:
            return try await buildRemoteFileEffectiveConnection(
                for: connection,
                sshPasswordOverride: sshPasswordOverride,
                deadline: deadline
            )
        case .remoteDatabaseSession:
            return try await buildRemoteSQLiteEffectiveConnection(
                for: connection,
                sshPasswordOverride: sshPasswordOverride,
                deadline: deadline
            )
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

        guard ownsAttempt() else { throw CancellationError() }
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
            totpPeriod: sshConfig.totpPeriod,
            deadline: deadline
        )
        if let dialed = await SSHTunnelManager.shared.dialedRoute(connectionId: connection.id) {
            connectionStorage.recordDialedSSHRoute(dialed, for: connection.id) {
                SSHProfileStorage.shared.refreshingLinkedProfile($0)
            }
        }

        return tunneledConnection(
            from: connection,
            localPort: tunnelPort,
            forwardsToUnixSocket: destination.isUnixSocket
        )
    }

    // MARK: - SSH Tunnel Recovery

    func handleSSHTunnelDied(connectionId: UUID) async {
        recoverDeadTunnel(
            connectionId: connectionId,
            kind: "SSH",
            disconnectedMessage: String(localized: "SSH tunnel disconnected.")
        )
    }
}
