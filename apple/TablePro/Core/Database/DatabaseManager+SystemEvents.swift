//
//  DatabaseManager+SystemEvents.swift
//  TablePro
//

import AppKit
import Foundation
import os

// MARK: - System Event Handling

extension DatabaseManager {
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
            // The clock moved while nothing observed it, so every answer held predates the sleep.
            self.forgetAllVerifications()
            await self.validateTunneledSessions()
        }
    }

    // Each handler only starts its session's loop, so every dead tunnel recovers at once.
    internal func validateTunneledSessions() async {
        for (connectionId, session) in activeSessions where session.isConnected && session.liveness == .live {
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
            case .socksProxy:
                await handleSOCKSProxyTunnelDied(connectionId: connectionId)
            case .tunnelCommand:
                await handleTunnelCommandDied(connectionId: connectionId)
            case .remoteFile:
                break
            case .remoteDatabaseSession:
                await handleRemoteSQLiteTunnelDied(connectionId: connectionId)
            }
        }
    }
}
