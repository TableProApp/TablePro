//
//  DatabaseManager+CloudSQLProxy.swift
//  TablePro
//

import Foundation

extension DatabaseManager {
    func buildCloudSQLProxyEffectiveConnection(
        for connection: DatabaseConnection
    ) async throws -> DatabaseConnection {
        guard let config = connection.resolvedCloudSQLProxyConfig else { return connection }

        let serviceAccountKeyJSON = config.authMode == .serviceAccountKey
            ? connectionStorage.loadCloudSQLProxyServiceAccountKey(for: connection.id)
            : nil

        let tunnelPort = try await CloudSQLProxyManager.shared.createTunnel(
            connectionId: connection.id,
            config: config,
            serviceAccountKeyJSON: serviceAccountKeyJSON
        )

        return tunneledConnection(from: connection, localPort: tunnelPort)
    }

    func handleCloudSQLProxyTunnelDied(connectionId: UUID) async {
        await recoverDeadTunnel(
            connectionId: connectionId,
            kind: "Cloud SQL Auth Proxy",
            disconnectedMessage: String(localized: "Cloud SQL Auth Proxy disconnected. Click to reconnect.")
        )
    }
}
