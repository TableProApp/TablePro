//
//  ConnectionTreeStatus.swift
//  TablePro
//

import Foundation

/// What a connection row in the sidebar tree says about itself.
///
/// The tree lists every saved connection, and most of them are not hosted by any window, so
/// `ConnectionWindowPhase` alone cannot answer: it exists only once a workspace does. A missing
/// phase and an idle one are the same row, which is the whole reason this is a separate vocabulary
/// rather than an optional phase passed around.
internal enum ConnectionTreeStatus: Equatable, Sendable {
    case notConnected
    case connecting
    case connected
    case failed

    internal init(phase: ConnectionWindowPhase?) {
        guard let phase else {
            self = .notConnected
            return
        }
        switch phase {
        case .idle, .closing:
            self = .notConnected
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .unavailable(let reason):
            self = Self(reason: reason)
        }
    }

    /// A connect the user called off, and one they ended themselves, leave a connection exactly as
    /// it was before they opened it. Only a failure the user did not ask for marks the row.
    private init(reason: ConnectionUnavailableReason) {
        switch reason {
        case .notConnected, .cancelled, .disconnectedByUser:
            self = .notConnected
        case .disconnected, .failed, .actionRequired:
            self = .failed
        }
    }

    /// Whether the row has a database tree under it. Only a live session does; everything else has
    /// a connection to make first.
    internal var hasObjects: Bool {
        self == .connected
    }

    internal var allowsConnect: Bool {
        switch self {
        case .notConnected, .failed: return true
        case .connecting, .connected: return false
        }
    }
}
