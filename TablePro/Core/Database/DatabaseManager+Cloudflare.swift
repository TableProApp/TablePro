//
//  DatabaseManager+Cloudflare.swift
//  TablePro
//

import Foundation

// MARK: - Cloudflare Tunnel Helper

extension DatabaseManager {
    /// Build an effective connection for a Cloudflare-tunneled database connection.
    /// Starts the cloudflared process and returns a connection pointing at the
    /// local loopback port the tunnel listens on.
    func buildCloudflareEffectiveConnection(
        for connection: DatabaseConnection
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
            tokenSecret: tokenSecret
        )

        return tunneledConnection(from: connection, localPort: tunnelPort)
    }

    // MARK: - Cloudflare Tunnel Recovery

    /// Handle Cloudflare tunnel death by reconnecting with exponential backoff.
    /// Guarded by `recoveringConnectionIds` to prevent duplicate concurrent recovery.
    func handleCloudflareTunnelDied(connectionId: UUID) async {
        await recoverDeadTunnel(
            connectionId: connectionId,
            kind: "Cloudflare",
            disconnectedMessage: String(localized: "Cloudflare tunnel disconnected. Click to reconnect.")
        )
    }
}
