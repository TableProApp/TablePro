//
//  DatabaseManager+SystemEvents.swift
//  TablePro
//
//  Handles macOS system events (sleep/wake, network changes) that affect
//  database connections, particularly SSH-tunneled sessions.
//

import AppKit
import Foundation
import os

// MARK: - System Event Handling

extension DatabaseManager {
    /// Begin observing system events that affect connection health.
    /// Call once from `applicationDidFinishLaunching`.
    func startObservingSystemEvents() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleSystemDidWake(_ notification: Notification) {
        Self.logger.info("System woke from sleep, validating tunneled sessions")

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.validateTunneledSessions()
        }
    }

    /// After waking from sleep, proactively check all tunneled sessions.
    /// If the tunnel is dead, trigger an immediate reconnect rather than waiting
    /// for the next 30-second health monitor ping.
    private func validateTunneledSessions() async {
        for (connectionId, session) in activeSessions where session.isConnected {
            if session.connection.resolvedSSHConfig.enabled {
                let tunnelAlive = await SSHTunnelManager.shared.hasTunnel(connectionId: connectionId)
                if !tunnelAlive {
                    Self.logger.warning("SSH tunnel missing after wake for: \(session.connection.name)")
                    await handleSSHTunnelDied(connectionId: connectionId)
                }
            } else if session.connection.isCloudflareEnabled {
                let tunnelAlive = await CloudflareTunnelManager.shared.hasTunnel(connectionId: connectionId)
                if !tunnelAlive {
                    Self.logger.warning("Cloudflare tunnel missing after wake for: \(session.connection.name)")
                    await handleCloudflareTunnelDied(connectionId: connectionId)
                }
            }
        }
    }
}
