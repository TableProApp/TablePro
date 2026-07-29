//
//  DatabaseManager+SOCKSProxy.swift
//  TablePro
//

import Foundation

extension DatabaseManager {
    func buildSOCKSProxyEffectiveConnection(
        for connection: DatabaseConnection
    ) async throws -> DatabaseConnection {
        guard let config = connection.resolvedSOCKSProxyConfig else { return connection }

        let password = config.username.isEmpty
            ? nil
            : connectionStorage.loadSOCKSProxyPassword(for: connection.id)

        let tunnelPort = try await SOCKSProxyManager.shared.createTunnel(
            connectionId: connection.id,
            config: config,
            password: password,
            targetHost: connection.host,
            targetPort: connection.port
        )

        return tunneledConnection(from: connection, localPort: tunnelPort)
    }

    func handleSOCKSProxyTunnelDied(connectionId: UUID) async {
        await recoverDeadTunnel(
            connectionId: connectionId,
            kind: "SOCKS Proxy",
            disconnectedMessage: String(localized: "SOCKS proxy disconnected. Click to reconnect.")
        )
    }
}
