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
