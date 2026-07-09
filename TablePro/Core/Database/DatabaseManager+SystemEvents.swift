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
            guard let kind = session.connection.activeTunnelKind,
                  let manager = activeTunnelManager(for: session.connection) else { continue }
            let tunnelAlive = await manager.hasTunnel(connectionId: connectionId)
            guard !tunnelAlive else { continue }
            Self.logger.warning("\(kind.displayName) missing after wake for: \(session.connection.name)")
            switch kind {
            case .ssh:
                await handleSSHTunnelDied(connectionId: connectionId)
            case .cloudflare:
                await handleCloudflareTunnelDied(connectionId: connectionId)
            case .cloudSQLProxy:
                await handleCloudSQLProxyTunnelDied(connectionId: connectionId)
            }
        }
    }
}
