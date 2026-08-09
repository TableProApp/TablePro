//
//  MainSplitViewController+Connection.swift
//  TablePro
//

import AppKit
import Foundation
import os

internal extension MainSplitViewController {
    private static var connectionLogger: Logger {
        Logger(subsystem: "com.TablePro", category: "ConnectionWindow")
    }

    func startActivationConnectIfNeeded() {
        guard autoConnect else { return }
        guard ConnectionWindowPhaseMachine.allowsActivationConnect(phase: phase) else { return }
        guard let connection = payloadConnection else { return }
        guard DatabaseManager.shared.activeSessions[connection.id]?.driver == nil else { return }
        connect(connection, cancellingPrevious: false)
    }

    func retryConnection() {
        guard let connection = payloadConnection else { return }
        connect(connection, cancellingPrevious: true)
    }

    func cancelConnectionAttempt() {
        attemptToken = nil
        transition(to: .unavailable(.cancelled))
        guard let connectionId = payload?.connectionId else { return }
        DatabaseManager.shared.invalidateConnectionAttempt(connectionId)
        Task { await DatabaseManager.shared.cancelEnsureConnected(connectionId) }
    }

    func openConnectionList() {
        WindowOpener.shared.openWelcome()
    }

    func performUnavailablePrimaryAction(_ reason: ConnectionUnavailableReason) {
        switch reason {
        case .pluginMissing:
            guard let connection = payloadConnection else { return }
            WelcomeRouter.shared.routePluginInstall(connection)
        case .notConnected, .cancelled, .disconnected, .failed:
            retryConnection()
        }
    }

    private func connect(_ connection: DatabaseConnection, cancellingPrevious: Bool) {
        let token = UUID()
        attemptToken = token
        transition(to: ConnectionWindowPhaseMachine.onAttemptStarted(phase: phase))

        Task { [weak self] in
            if cancellingPrevious {
                await DatabaseManager.shared.cancelEnsureConnected(connection.id)
            }
            do {
                try await DatabaseManager.shared.ensureConnected(connection)
                self?.finishAttempt(token, outcome: nil)
            } catch {
                Self.connectionLogger.error(
                    "Connect failed for \(connection.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                self?.finishAttempt(token, outcome: ConnectionFailureClassifier.outcome(for: error))
            }
        }
    }

    private func finishAttempt(_ token: UUID, outcome: ConnectionAttemptOutcome?) {
        let isCurrentAttempt = attemptToken == token
        if isCurrentAttempt { attemptToken = nil }

        guard let outcome else {
            refreshFromActiveSessions()
            return
        }

        transition(
            to: ConnectionWindowPhaseMachine.onAttemptFinished(
                phase: phase,
                isCurrentAttempt: isCurrentAttempt,
                outcome: outcome
            )
        )
    }
}
