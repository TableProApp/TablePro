//
//  DatabaseManager+SSH.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import Foundation

import TableProConnectionLibrary
import TableProSSHConfig
import TableProSSHTransport

// MARK: - SSH Tunnel Helper

extension DatabaseManager {
    // `sshPasswordOverride` is the password Test Connection typed, used instead of the stored one.
    // `ownsAttempt` is asked with nothing suspending before the tunnel is created: tunnels are keyed by
    // connection, and creating one closes whatever a newer attempt opened under the same id.
    // `pinnedSSHRoute` is the route an open session dialed: a linked profile moved since then is refused, not followed.
    internal func buildEffectiveConnection(
        for original: DatabaseConnection,
        sshPasswordOverride: String? = nil,
        pinnedSSHRoute: ConnectionDestination.Tunnel? = nil,
        deadline: ConnectionDeadline,
        ownsAttempt: () -> Bool = { true }
    ) async throws -> DatabaseConnection {
        var connection = try routedThroughLinkedProfile(original, pinnedSSHRoute: pinnedSSHRoute)
        // Only the tunnel this connect opens says it secures the transport or names the server behind it; a saved or
        // imported field never does.
        connection.additionalFields[DatabaseConnection.tunnelSecuresTransportKey] = nil
        connection.additionalFields[DatabaseConnection.preTunnelHostKey] = nil
        connection.additionalFields[DatabaseConnection.preTunnelPortKey] = nil
        // Only a remote SQLite session sets these; a stored pair would send every statement to the row's host.
        connection.additionalFields[RemoteSQLiteWire.backendFieldKey] = nil
        connection.additionalFields[RemoteSQLiteWire.tokenFieldKey] = nil
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
        // The stored flag alone is not enough: a driver that dials no forwarded port goes around the tunnel.
        guard enabledKinds.first == .ssh, sshConfig.enabled else { return connection }

        if case .disabled = connection.sshTunnelMode { return connection }
        return try await openSSHTunnel(
            for: connection,
            sshConfig: sshConfig,
            sshPasswordOverride: sshPasswordOverride,
            deadline: deadline,
            ownsAttempt: ownsAttempt
        )
    }

    private func openSSHTunnel(
        for connection: DatabaseConnection,
        sshConfig: SSHConfiguration,
        sshPasswordOverride: String?,
        deadline: ConnectionDeadline,
        ownsAttempt: () -> Bool
    ) async throws -> DatabaseConnection {
        let credentials = await sshCredentials(for: connection, passwordOverride: sshPasswordOverride)
        let destination = connection.sshForwardDestination

        guard ownsAttempt() else { throw CancellationError() }
        let tunnelPort = try await SSHTunnelManager.shared.createTunnel(
            connectionId: connection.id,
            sshHost: sshConfig.host,
            sshPort: sshConfig.port,
            sshUsername: sshConfig.username,
            authMethod: sshConfig.authMethod,
            privateKeyPath: sshConfig.privateKeyPath,
            keyPassphrase: credentials.keyPassphrase,
            sshPassword: credentials.sshPassword,
            agentSocketPath: sshConfig.agentSocketPath,
            destination: destination,
            jumpHosts: sshConfig.jumpHosts,
            totpMode: sshConfig.totpMode,
            totpSecret: credentials.totpSecret,
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

    internal func routedThroughLinkedProfile(
        _ connection: DatabaseConnection,
        pinnedSSHRoute: ConnectionDestination.Tunnel?
    ) throws -> DatabaseConnection {
        let routed = SSHProfileStorage.shared.refreshingLinkedProfile(connection)
        if let pinnedSSHRoute, case .profile = routed.sshTunnelMode, routed.destinationTunnel != pinnedSSHRoute {
            throw ConnectionTunnelError.sshProfileMoved
        }
        return routed
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
