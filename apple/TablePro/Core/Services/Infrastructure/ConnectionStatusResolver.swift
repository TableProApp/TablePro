//
//  ConnectionStatusResolver.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

// The one place a connection's state becomes a `ConnectionDisplayStatus`, so the rail, Welcome,
// the switcher, the pane, the toolbar and the menus all name the same state for the same facts.
internal enum ConnectionStatusResolver {
    internal static func status(phase: ConnectionWindowPhase, session: ConnectionSession?) -> ConnectionDisplayStatus {
        switch phase {
        case .connecting:
            return .connecting
        case .connected:
            guard let recovery = session?.recovery else { return .connected }
            return .reconnecting(attempt: recovery.attempt, of: recovery.maxAttempts)
        case .unavailable(let reason):
            switch reason {
            case .failed(let info), .actionRequired(let info, _):
                return .failed(cause: info.message)
            case .disconnected(let info):
                return .lost(cause: info?.message)
            case .notConnected, .cancelled, .disconnectedByUser:
                return .notConnected
            }
        case .idle, .closing:
            return .notConnected
        }
    }

    // Mirrors the phase machine: an installed driver reads as connected unless it was declared
    // unreachable, so a database switch that writes `.connecting` does not spin a row.
    internal static func status(
        session: ConnectionSession?,
        endReason: ConnectionEndReason?,
        disconnectedByUser: Bool = false
    ) -> ConnectionDisplayStatus {
        if let session {
            if case .unreachable(let info) = session.liveness {
                return .lost(cause: info?.message ?? endReason?.info.message)
            }
            if let recovery = session.recovery {
                return .reconnecting(attempt: recovery.attempt, of: recovery.maxAttempts)
            }
            if session.driver != nil { return .connected }
            switch session.status {
            case .connecting:
                return .connecting
            case .connected:
                return .connected
            case .error(let message):
                return .lost(cause: message)
            case .disconnected:
                break
            }
        }
        guard !disconnectedByUser, let endReason else { return .notConnected }
        switch endReason {
        case .connectFailed(let info, _):
            return .failed(cause: info.message)
        case .sessionLost(let info):
            return .lost(cause: info.message)
        }
    }

    // A hosted workspace's phase wins over the session. Two windows can host one connection, and
    // then the one with work in flight speaks for it.
    internal static func status(
        phases: [ConnectionWindowPhase],
        session: ConnectionSession?,
        endReason: ConnectionEndReason?,
        disconnectedByUser: Bool = false
    ) -> ConnectionDisplayStatus {
        let hosted = phases.map { status(phase: $0, session: session) }
        guard let first = hosted.first else {
            return status(session: session, endReason: endReason, disconnectedByUser: disconnectedByUser)
        }
        return hosted.dropFirst().reduce(first) { rank(of: $1) > rank(of: $0) ? $1 : $0 }
    }

    @MainActor
    internal static func status(for connectionId: UUID) -> ConnectionDisplayStatus {
        let manager = DatabaseManager.shared
        return status(
            phases: WindowManager.shared.workspaces(for: connectionId).map(\.phase),
            session: manager.activeSessions[connectionId],
            endReason: manager.disconnectReason(for: connectionId),
            disconnectedByUser: manager.wasDisconnectedByUser(connectionId)
        )
    }

    // The live session, not the workspace's adopted copy: the reconnect loop advances its attempt
    // on the manager's entry before any window has reconciled.
    @MainActor
    internal static func status(of workspace: ConnectionWorkspace) -> ConnectionDisplayStatus {
        status(
            phase: workspace.phase,
            session: DatabaseManager.shared.activeSessions[workspace.connectionId] ?? workspace.session
        )
    }

    private static func rank(of status: ConnectionDisplayStatus) -> Int {
        switch status {
        case .reconnecting: 5
        case .connecting: 4
        case .lost: 3
        case .failed: 2
        case .connected: 1
        case .notConnected: 0
        }
    }
}

internal extension ConnectionStatusPresentation {
    // A context menu names the command after what it acts on, so Cancel says what it stops.
    var primaryActionTitle: String? {
        switch primaryAction {
        case .connect:
            return String(localized: "Connect")
        case .reconnect:
            return String(localized: "Reconnect")
        case .cancel:
            if case .reconnecting = status { return String(localized: "Stop Reconnecting") }
            return String(localized: "Stop Connecting")
        case nil:
            return nil
        }
    }
}
