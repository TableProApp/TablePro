//
//  ConnectionWindowPhaseMachine.swift
//  TablePro
//

import Foundation

/// `exists` and `hasDriver` alone cannot tell "still dialing" from "gave up", which is why a
/// session left behind by an exhausted tunnel recovery used to read as `.connecting` forever.
/// `disconnectInfo` carries the reason the session went away so the window can say what happened
/// instead of falling back to the generic closed-connection copy.
internal struct ConnectionSessionSnapshot: Equatable, Sendable {
    internal let exists: Bool
    internal let hasDriver: Bool
    internal let disconnectInfo: ConnectionFailureInfo?
    /// The user asked for this. A session that goes away on its own is something to report and
    /// recover from; one the user ended is neither, and it must not be replayed on the next launch.
    internal let wasDisconnectedByUser: Bool
    /// Whether the driver `hasDriver` reports can be believed. Without it the machine can only ask
    /// whether a handle is installed, which stays true across an outage and after a reconnect has
    /// given up.
    internal let liveness: ConnectionLiveness

    internal init(
        exists: Bool,
        hasDriver: Bool,
        disconnectInfo: ConnectionFailureInfo? = nil,
        wasDisconnectedByUser: Bool = false,
        liveness: ConnectionLiveness = .live
    ) {
        self.exists = exists
        self.hasDriver = hasDriver
        self.disconnectInfo = disconnectInfo
        self.wasDisconnectedByUser = wasDisconnectedByUser
        self.liveness = liveness
    }

    internal static let absent = ConnectionSessionSnapshot(exists: false, hasDriver: false)

    internal var lostSessionReason: ConnectionUnavailableReason {
        wasDisconnectedByUser ? .disconnectedByUser : .disconnected(disconnectInfo)
    }
}

internal enum ConnectionWindowPhaseMachine {
    internal static func onWindowClosing(phase: ConnectionWindowPhase) -> ConnectionWindowPhase {
        .closing
    }

    internal static func onAttemptStarted(phase: ConnectionWindowPhase) -> ConnectionWindowPhase {
        guard phase != .closing else { return .closing }
        return .connecting
    }

    /// A session whose driver has stopped answering is reported before the driver itself is, because
    /// the handle outlives the connection: a reconnect disconnects it and leaves it installed, so
    /// `hasDriver` stays true for the whole of an outage and for good once the monitor gives up.
    ///
    /// `ownsAttempt` still wins. A workspace that has just asked to reconnect is dialing, not
    /// unreachable, and a stale report from the attempt it replaced must not drag it back.
    internal static func onSessionChanged(
        phase: ConnectionWindowPhase,
        session: ConnectionSessionSnapshot,
        ownsAttempt: Bool
    ) -> ConnectionWindowPhase {
        guard phase != .closing else { return .closing }
        if session.exists, case .unreachable(let info) = session.liveness {
            /// A workspace that asked to reconnect is dialing. Reading the still-installed driver as
            /// connected would put its rows back on screen for the length of its own reconnect, over
            /// the very handle that stopped answering.
            guard !ownsAttempt else { return .connecting }
            return .unavailable(.disconnected(info ?? session.disconnectInfo))
        }
        if session.hasDriver { return .connected }

        if session.exists {
            if case .unavailable = phase { return phase }
            return .connecting
        }

        switch phase {
        case .connecting:
            return ownsAttempt ? .connecting : .unavailable(session.lostSessionReason)
        case .connected:
            return .unavailable(session.lostSessionReason)
        case .idle, .unavailable, .closing:
            return phase
        }
    }

    internal static func onAttemptFinished(
        phase: ConnectionWindowPhase,
        isCurrentAttempt: Bool,
        outcome: ConnectionAttemptOutcome
    ) -> ConnectionWindowPhase {
        guard phase != .closing else { return .closing }
        guard isCurrentAttempt else { return phase }
        guard phase != .connected else { return .connected }

        switch outcome {
        case .cancelled:
            return .unavailable(.cancelled)
        case .failed(let info):
            return .unavailable(.failed(info))
        case .pluginMissing(let info):
            return .unavailable(.pluginMissing(info))
        }
    }

    internal static func retainsRestoreIntent(phase: ConnectionWindowPhase) -> Bool {
        switch phase {
        case .connecting, .connected:
            return true
        case .unavailable(let reason):
            switch reason {
            case .cancelled, .disconnectedByUser:
                return false
            case .notConnected, .disconnected, .failed, .pluginMissing:
                return true
            }
        case .idle, .closing:
            return false
        }
    }

    /// Whether the user can ask this window to connect. Distinct from `allowsActivationConnect`,
    /// which answers whether the app may dial on its own: a window the user disconnected must not
    /// reconnect just because they clicked back into it, but Reconnect has to stay available.
    internal static func allowsManualConnect(phase: ConnectionWindowPhase) -> Bool {
        switch phase {
        case .idle:
            return true
        case .unavailable(let reason):
            switch reason {
            case .notConnected, .cancelled, .disconnected, .disconnectedByUser, .failed:
                return true
            case .pluginMissing:
                return false
            }
        case .connecting, .connected, .closing:
            return false
        }
    }

    internal static func allowsActivationConnect(phase: ConnectionWindowPhase) -> Bool {
        switch phase {
        case .idle:
            return true
        case .unavailable(let reason):
            switch reason {
            case .notConnected, .disconnected, .failed:
                return true
            case .cancelled, .disconnectedByUser, .pluginMissing:
                return false
            }
        case .connecting, .connected, .closing:
            return false
        }
    }
}
