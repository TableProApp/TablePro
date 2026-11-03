//
//  DatabaseManager+TunnelCommand.swift
//  TablePro
//

import Foundation

extension DatabaseManager {
    func buildTunnelCommandEffectiveConnection(
        for connection: DatabaseConnection,
        deadline: ConnectionDeadline,
        ownsAttempt: () -> Bool = { true }
    ) async throws -> DatabaseConnection {
        guard let config = connection.resolvedTunnelCommandConfig else { return connection }

        // The command runs code from user-writable storage; re-saving the connection in the app trusts it again.
        guard await ConnectionStorage.shared.storeIsTrusted else {
            throw TunnelCommandError.storeNotTrusted
        }
        guard ownsAttempt() else { throw CancellationError() }

        let endpoint = connection.tunnelForwardEndpoint
        let tunnelPort = try await TunnelCommandManager.shared.createTunnel(
            connectionId: connection.id,
            config: config,
            remoteHost: endpoint.host,
            remotePort: endpoint.port,
            deadline: deadline
        )

        return tunneledConnection(from: connection, localPort: tunnelPort)
    }

    func handleTunnelCommandDied(connectionId: UUID) async {
        recoverDeadTunnel(
            connectionId: connectionId,
            kind: "Tunnel command",
            disconnectedMessage: String(localized: "The tunnel command stopped.")
        )
    }
}
