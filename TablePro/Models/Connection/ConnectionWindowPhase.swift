//
//  ConnectionWindowPhase.swift
//  TablePro
//

import Foundation

internal struct ConnectionFailureInfo: Equatable, Sendable {
    internal let message: String
    internal let failureReason: String?
    internal let recoverySuggestion: String?

    internal init(message: String, failureReason: String? = nil, recoverySuggestion: String? = nil) {
        self.message = message
        self.failureReason = failureReason
        self.recoverySuggestion = recoverySuggestion
    }
}

/// Whether a session's driver is worth trusting, which is a different question from whether one is
/// installed.
///
/// `ConnectionSession.driver` is a handle: the app holds it from the moment it is built until
/// something replaces it, and a socket the server closed looks exactly like a working one until a
/// ping asks. So the window used to keep showing rows over a driver a reconnect had already
/// disconnected, for the whole of an outage and permanently after the monitor gave up, while the
/// connections strip painted the failure from the other channel.
///
/// `recovering` is deliberately not a failure. A reconnect that finishes in a few seconds is a blip
/// the user should never see, so the rows, the tabs and the toolbar stay exactly as they were. It
/// becomes `unreachable` once it has been failing long enough that leaving them up is a lie.
internal enum ConnectionLiveness: Equatable, Sendable {
    case live
    case recovering
    case unreachable(ConnectionFailureInfo?)
}

internal enum ConnectionUnavailableReason: Equatable, Sendable {
    case notConnected
    case cancelled
    case disconnected(ConnectionFailureInfo?)
    case disconnectedByUser
    case failed(ConnectionFailureInfo)
    case pluginMissing(ConnectionFailureInfo)
}

internal enum ConnectionWindowPhase: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case unavailable(ConnectionUnavailableReason)
    case closing
}

internal enum ConnectionAttemptOutcome: Equatable, Sendable {
    case cancelled
    case failed(ConnectionFailureInfo)
    case pluginMissing(ConnectionFailureInfo)
}
