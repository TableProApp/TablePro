//
//  DatabaseManager+EnsureConnected.swift
//  TablePro
//

import Foundation
import os

extension DatabaseManager {
    func ensureConnected(
        _ connection: DatabaseConnection,
        passwordOverride: String? = nil,
        sshPasswordOverride: String? = nil,
        trigger: ConnectTrigger = .request,
        adoptsSSHProfileEdits: Bool = false
    ) async throws {
        // A driver is a reason to skip only while it answers: one a reconnect gave up on made Reconnect do nothing.
        await verifyBeforeUse(connection.id)
        if let session = activeSessions[connection.id], session.driver != nil, session.liveness == .live {
            return
        }
        try await ensureConnectedDedup.execute(key: connection.id) {
            try await self.connectToSession(
                connection,
                passwordOverride: passwordOverride,
                sshPasswordOverride: sshPasswordOverride,
                trigger: trigger,
                adoptsSSHProfileEdits: adoptsSSHProfileEdits
            )
        }
    }

    func invalidateConnectionAttempt(_ connectionId: UUID) {
        connectionAttempts.invalidate(for: connectionId)
        clearConnectionStage(for: connectionId)
        preConnectScriptConsent.withdrawApproval(for: connectionId)
    }

    func cancelEnsureConnected(_ connectionId: UUID) async {
        connectionAttempts.invalidate(for: connectionId)
        clearConnectionStage(for: connectionId)
        await ensureConnectedDedup.cancel(key: connectionId)
        if let session = activeSessions[connectionId], session.driver == nil {
            if let tunnelManager = activeTunnelManager(for: session.connection) {
                do {
                    try await tunnelManager.closeTunnel(connectionId: connectionId)
                } catch {
                    Self.logger.warning("Tunnel cleanup failed for \(connectionId): \(error.localizedDescription)")
                }
            }
            removeSessionEntry(for: connectionId)
            if lastActiveSessionId == connectionId {
                lastActiveSessionId = nil
            }
        }
    }
}
