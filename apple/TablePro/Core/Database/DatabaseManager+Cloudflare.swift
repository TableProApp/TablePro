//
//  DatabaseManager+Cloudflare.swift
//  TablePro
//

import Foundation

// MARK: - Cloudflare Tunnel Helper

extension DatabaseManager {
    func buildCloudflareEffectiveConnection(
        for connection: DatabaseConnection,
        deadline: ConnectionDeadline
    ) async throws -> DatabaseConnection {
        guard let config = connection.resolvedCloudflareConfig else { return connection }

        let tokenId: String?
        let tokenSecret: String?
        if config.authMethod == .serviceToken {
            tokenId = connectionStorage.loadCloudflareTokenId(for: connection.id)
            tokenSecret = connectionStorage.loadCloudflareTokenSecret(for: connection.id)
        } else {
            tokenId = nil
            tokenSecret = nil
        }

        let tunnelPort = try await CloudflareTunnelManager.shared.createTunnel(
            connectionId: connection.id,
            config: config,
            tokenId: tokenId,
            tokenSecret: tokenSecret,
            deadline: deadline
        )

        return tunneledConnection(from: connection, localPort: tunnelPort)
    }

    // MARK: - Cloudflare Tunnel Recovery

    func handleCloudflareTunnelDied(connectionId: UUID) async {
        recoverDeadTunnel(
            connectionId: connectionId,
            kind: "Cloudflare",
            disconnectedMessage: String(localized: "Cloudflare tunnel disconnected.")
        )
    }
}
