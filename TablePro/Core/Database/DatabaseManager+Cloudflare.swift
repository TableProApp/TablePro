//
//  DatabaseManager+Cloudflare.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

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

        // The driver connects to 127.0.0.1, so hostname-based certificate
        // verification can't match the origin. Keep transport encryption but
        // drop verification and local-only cert paths, mirroring SSH tunneling.
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

    // MARK: - Cloudflare Tunnel Recovery

    /// Handle Cloudflare tunnel death by reconnecting with exponential backoff.
    /// Guarded by `recoveringConnectionIds` to prevent duplicate concurrent recovery.
    func handleCloudflareTunnelDied(connectionId: UUID) async {
        guard let session = activeSessions[connectionId],
              !recoveringConnectionIds.contains(connectionId) else { return }

        recoveringConnectionIds.insert(connectionId)
        defer { recoveringConnectionIds.remove(connectionId) }

        Self.logger.warning("Cloudflare tunnel died for connection: \(session.connection.name)")

        await stopHealthMonitor(for: connectionId)

        activeSessions[connectionId]?.driver?.disconnect()
        updateSession(connectionId) { session in
            session.driver = nil
            session.status = .connecting
        }

        let maxRetries = 10
        for retryCount in 0..<maxRetries {
            let delay = ExponentialBackoff.delay(for: retryCount + 1, maxDelay: 120)
            Self.logger.info("Cloudflare reconnect attempt \(retryCount + 1)/\(maxRetries) in \(delay)s for: \(session.connection.name)")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            do {
                try await connectToSession(session.connection)
                Self.logger.info("Successfully reconnected Cloudflare tunnel for: \(session.connection.name)")
                return
            } catch {
                Self.logger.warning("Cloudflare reconnect attempt \(retryCount + 1) failed: \(error.localizedDescription)")
            }
        }

        Self.logger.error("All Cloudflare reconnect attempts failed for: \(session.connection.name)")

        updateSession(connectionId) { session in
            session.status = .error(String(localized: "Cloudflare tunnel disconnected. Click to reconnect."))
            session.clearCachedData()
        }
    }
}
