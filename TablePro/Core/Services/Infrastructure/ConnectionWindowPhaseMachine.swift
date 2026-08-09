//
//  ConnectionWindowPhaseMachine.swift
//  TablePro
//

import Foundation

internal struct ConnectionSessionSnapshot: Equatable, Sendable {
    internal let exists: Bool
    internal let hasDriver: Bool

    internal static let absent = ConnectionSessionSnapshot(exists: false, hasDriver: false)
}

internal enum ConnectionWindowPhaseMachine {
    internal static func onWindowClosing(phase: ConnectionWindowPhase) -> ConnectionWindowPhase {
        .closing
    }

    internal static func onAttemptStarted(phase: ConnectionWindowPhase) -> ConnectionWindowPhase {
        guard phase != .closing else { return .closing }
        return .connecting
    }

    internal static func onSessionChanged(
        phase: ConnectionWindowPhase,
        session: ConnectionSessionSnapshot,
        ownsAttempt: Bool
    ) -> ConnectionWindowPhase {
        guard phase != .closing else { return .closing }
        if session.hasDriver { return .connected }

        if session.exists {
            if case .unavailable = phase { return phase }
            return .connecting
        }

        switch phase {
        case .connecting:
            return ownsAttempt ? .connecting : .unavailable(.disconnected)
        case .connected:
            return .unavailable(.disconnected)
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
            case .notConnected, .cancelled:
                return false
            case .disconnected, .failed, .pluginMissing:
                return true
            }
        case .idle, .closing:
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
            case .cancelled, .pluginMissing:
                return false
            }
        case .connecting, .connected, .closing:
            return false
        }
    }
}
