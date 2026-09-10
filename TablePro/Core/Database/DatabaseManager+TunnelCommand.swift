//
//  DatabaseManager+TunnelCommand.swift
//  TablePro
//

import Foundation

extension DatabaseManager {
    func buildTunnelCommandEffectiveConnection(
        for connection: DatabaseConnection
    ) async throws -> DatabaseConnection {
        guard let config = connection.resolvedTunnelCommandConfig else { return connection }

        /// The command is the one part of a connection that runs code, and `connections.json` is
        /// ordinary user-writable storage. `ConnectionStoreIntegrity` already answers whether the
        /// file is the one TablePro last wrote, and re-saving the connection in the app is the
        /// confirmation that clears it, exactly as it is for a password source.
        guard await ConnectionStorage.shared.storeIsTrusted else {
            throw TunnelCommandError.storeNotTrusted
        }

        let endpoint = connection.tunnelForwardEndpoint
        let tunnelPort = try await TunnelCommandManager.shared.createTunnel(
            connectionId: connection.id,
            config: config,
            remoteHost: endpoint.host,
            remotePort: endpoint.port
        )

        return tunneledConnection(from: connection, localPort: tunnelPort)
    }

    func handleTunnelCommandDied(connectionId: UUID) async {
        await recoverDeadTunnel(
            connectionId: connectionId,
            kind: "Tunnel command",
            disconnectedMessage: String(localized: "The tunnel command stopped. Click to reconnect.")
        )
    }
}
