//
//  MainSplitViewController+Connection.swift
//  TablePro
//

import AppKit
import Foundation
import os

/// The rail asks the window which connection it is showing rather than remembering one, so the
/// window answers from the registry that already knows.
extension MainSplitViewController: WorkspaceRailHost {
    internal var hostedConnectionIds: [UUID] { workspaces.connectionIds }

    internal var selectedConnectionId: UUID? { workspaces.selectedConnectionId }

    internal func selectHostedConnection(_ connectionId: UUID) {
        workspaces.select(connectionId)
    }
}

internal extension MainSplitViewController {
    private static var connectionLogger: Logger {
        Logger(subsystem: "com.TablePro", category: "ConnectionWindow")
    }

    /// Every path out of here settles the workspace, because a window that declines to dial and
    /// says nothing is a window the resolver can only answer for with a timeout, and a state
    /// reached by a timeout is a state nothing transitions into. That used to be the pane
    /// resolver's job: it reported nothing for half a second and then fell back to
    /// `.notConnected`, which is also what put a blank window on screen for the first half second
    /// of every connect.
    func startActivationConnectIfNeeded() {
        guard autoConnect else { return }
        guard ConnectionWindowPhaseMachine.allowsActivationConnect(phase: phase) else { return }
        /// A workspace whose record has gone still names a connection through its session, so the
        /// pane has something to draw and nothing to dial with.
        guard let connection = payloadConnection else {
            transition(to: .unavailable(.notConnected))
            return
        }
        /// A session that is already up is not a dial to skip quietly: the phase still says the
        /// window is coming up, and only a status pass moves it onto the session it already has.
        guard DatabaseManager.shared.activeSessions[connection.id]?.driver == nil else {
            refreshFromActiveSessions()
            return
        }

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
        guard let connectionId = workspaces.selectedConnectionId else { return }
        reconnectWorkspace(connectionId)
    }

    /// Reconnects the connection named, not whichever one the window happens to be showing.
    /// Clicking a disconnected connection used to redial the selected one instead, tearing down
    /// the session the user was working in.
    internal func reconnectWorkspace(_ connectionId: UUID) {
        guard let workspace = workspaces.workspace(for: connectionId),
              let connection = workspace.connection else { return }
        workspaces.select(connectionId)
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

    /// Hands the connection's database file back to the rest of the machine without ending the
    /// session, for the embedded engines that hold one. Asked of the live driver rather than of
    /// the database type, because a DuckDB connection to a Parquet file or a remote Quack server
    /// holds no file lock while its neighbour on a `.duckdb` file does.
    @objc func releaseFileLock(_ sender: Any?) {
        guard let connection = payloadConnection else { return }
        Task {
            await ConnectionFileLockAction.release(
                connectionId: connection.id,
                connectionName: connection.name,
                presentingWindow: view.window
            )
        }
    }

    var canReleaseFileLock: Bool {
        ConnectionFileLockAction.commandTitle(connectionId: workspaces.selectedConnectionId) != nil
    }

    var canDisconnect: Bool {
        payloadConnection != nil && phase == .connected
    }

    var canReconnect: Bool {
        payloadConnection != nil && ConnectionWindowPhaseMachine.allowsManualConnect(phase: phase)
    }

    func cancelConnectionAttempt(for connectionId: UUID) {
        guard let workspace = workspaces.workspace(for: connectionId) else { return }
        workspace.attemptToken = nil
        transition(to: .unavailable(.cancelled), for: connectionId)
        DatabaseManager.shared.invalidateConnectionAttempt(connectionId)
        Task { await DatabaseManager.shared.cancelEnsureConnected(connectionId) }
    }

    func openConnectionList() {
        WindowOpener.shared.openWelcome()
    }

    func performUnavailablePrimaryAction(_ reason: ConnectionUnavailableReason, for connectionId: UUID) {
        guard case .actionRequired(_, let action) = reason else {
            reconnectWorkspace(connectionId)
            return
        }
        guard let connection = workspaces.workspace(for: connectionId)?.connection else { return }
        ConnectionRecoveryPerformer.perform(action, for: connection) { [weak self] in
            self?.reconnectWorkspace(connectionId)
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
                if await self?.offerSignInAndReconnect(for: connection, error: error) == true {
                    return
                }
                self?.finishAttempt(
                    token,
                    for: connection.id,
                    outcome: ConnectionFailureClassifier.outcome(
                        for: error,
                        canEditConnection: ConnectionRecoveryPerformer.canEdit(connection)
                    )
                )
            }
        }
    }

    /// A connect that outlives the workspace it was started for has nothing to report to. The
    /// registry entry going away is the generation check: writing a phase back here would
    /// resurrect a connection the user already closed.
    /// A connect that failed only because a sign-in expired is recoverable, so offer it here rather
    /// than leaving the user on an error screen whose only button repeats the same failure.
    ///
    /// Returns true when a sign-in succeeded and a fresh attempt has started. The caller then skips
    /// `finishAttempt`, because `reconnectWorkspace` has already issued a new attempt token and this
    /// one is no longer current. Declining returns false and falls through to the normal failure.
    private func offerSignInAndReconnect(for connection: DatabaseConnection, error: Error) async -> Bool {
        guard let provider = ConnectionSignInRegistry.provider(
            for: error,
            fields: connection.additionalFields
        ) else {
            return false
        }
        let signedIn = await ConnectionSignInPrompt.offer(
            provider,
            fields: connection.additionalFields,
            window: view.window
        )
        guard signedIn else { return false }
        reconnectWorkspace(connection.id)
        return true
    }

    func adoptRecoverableConnectFailure(_ error: Error, for connectionId: UUID) -> Bool {
        guard let workspace = workspaces.workspace(for: connectionId),
              let connection = workspace.connection,
              ConnectionWindowPhaseMachine.acceptsExternalFailure(
                  phase: workspace.phase,
                  ownsAttempt: workspace.attemptToken != nil
              ) else { return false }
        let outcome = ConnectionFailureClassifier.outcome(
            for: error,
            canEditConnection: ConnectionRecoveryPerformer.canEdit(connection)
        )
        guard case .actionRequired = outcome else { return false }
        transition(
            to: ConnectionWindowPhaseMachine.onAttemptFinished(
                phase: workspace.phase,
                isCurrentAttempt: true,
                outcome: outcome
            ),
            for: connectionId
        )
        return true
    }

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
