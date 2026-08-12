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

        /// Reopening a session at launch is the app's gesture, not the user's, so it never runs a
        /// saved script on its own. The window waits in its not-connected state instead, where
        /// Connect asks first. Prompting here would also put one modal per restored connection on
        /// screen at startup, which the HIG rules out twice over.
        guard !connection.hasPreConnectScript else {
            transition(to: .unavailable(.notConnected))
            return
        }
        connect(connection, cancellingPrevious: false)
    }

    @objc func retryConnection() {
        guard let connection = payloadConnection else { return }
        connect(connection, cancellingPrevious: true)
    }

    /// The window stays open and repaints itself from its own phase once the session entry goes
    /// away, so this only has to end the session. Every other window on the connection hears the
    /// same status change and reaches the same phase on its own.
    @objc func requestDisconnect() {
        guard let connection = payloadConnection else { return }
        Task {
            await ConnectionDisconnectAction.disconnect(
                connectionId: connection.id,
                connectionName: connection.name,
                presentingWindow: view.window
            )
        }
    }

    var canDisconnect: Bool {
        payloadConnection != nil && phase == .connected
    }

    var canReconnect: Bool {
        payloadConnection != nil && ConnectionWindowPhaseMachine.allowsManualConnect(phase: phase)
    }

    func cancelConnectionAttempt() {
        guard let workspace = workspaces.selected else { return }
        workspace.attemptToken = nil
        transition(to: .unavailable(.cancelled), for: workspace.connectionId)
        DatabaseManager.shared.invalidateConnectionAttempt(workspace.connectionId)
        Task { await DatabaseManager.shared.cancelEnsureConnected(workspace.connectionId) }
    }

    func openConnectionList() {
        WindowOpener.shared.openWelcome()
    }

    func performUnavailablePrimaryAction(_ reason: ConnectionUnavailableReason) {
        switch reason {
        case .pluginMissing:
            guard let connection = payloadConnection else { return }
            WelcomeRouter.shared.routePluginInstall(connection)
        case .notConnected, .cancelled, .disconnected, .disconnectedByUser, .failed:
            retryConnection()
        }
    }

    private func connect(_ connection: DatabaseConnection, cancellingPrevious: Bool) {
        guard let workspace = workspaces.workspace(for: connection.id) else { return }
        let token = UUID()
        workspace.attemptToken = token
        transition(
            to: ConnectionWindowPhaseMachine.onAttemptStarted(phase: workspace.phase),
            for: connection.id
        )

        Task { [weak self] in
            guard await PreConnectScriptPrompt.confirmIfNeeded(for: connection) else {
                self?.finishAttempt(token, for: connection.id, outcome: .cancelled)
                return
            }
            if cancellingPrevious {
                await DatabaseManager.shared.cancelEnsureConnected(connection.id)
            }
            do {
                try await DatabaseManager.shared.ensureConnected(connection)
                self?.finishAttempt(token, for: connection.id, outcome: nil)
            } catch {
                Self.connectionLogger.error(
                    "Connect failed for \(connection.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                self?.finishAttempt(
                    token,
                    for: connection.id,
                    outcome: ConnectionFailureClassifier.outcome(for: error)
                )
            }
        }
    }

    /// A connect that outlives the workspace it was started for has nothing to report to. The
    /// registry entry going away is the generation check: writing a phase back here would
    /// resurrect a connection the user already closed.
    private func finishAttempt(_ token: UUID, for connectionId: UUID, outcome: ConnectionAttemptOutcome?) {
        guard let workspace = workspaces.workspace(for: connectionId) else { return }
        let isCurrentAttempt = workspace.attemptToken == token
        if isCurrentAttempt { workspace.attemptToken = nil }

        guard let outcome else {
            refreshFromActiveSessions()
            return
        }

        transition(
            to: ConnectionWindowPhaseMachine.onAttemptFinished(
                phase: workspace.phase,
                isCurrentAttempt: isCurrentAttempt,
                outcome: outcome
            ),
            for: connectionId
        )
    }
}
