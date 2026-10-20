//
//  SSHChannelFreePump.swift
//  TableProSSHTransport
//

import Foundation

public enum SSHChannelFreeAttempt: Equatable, Sendable {
    case finished
    case wouldBlock(RelayDirections)
}

public enum SSHChannelFreeOutcome: Equatable, Sendable {
    case freed
    case stopped
    case timedOut
}

// libssh2 keeps a CLOSE it could not send as the session's next packet and turns every other send
// away until the same free sends it, so a free never stops after a fixed number of tries: it runs
// until it finishes, the tunnel stops, or the deadline says the session is stuck.
public struct SSHChannelFreePump {
    public let attemptFree: () -> SSHChannelFreeAttempt
    public let isActive: () -> Bool
    public let deadline: Date
    public let waitForTransport: (RelayDirections) -> Void
    public var now: () -> Date

    public init(
        attemptFree: @escaping () -> SSHChannelFreeAttempt,
        isActive: @escaping () -> Bool,
        deadline: Date,
        waitForTransport: @escaping (RelayDirections) -> Void,
        now: @escaping () -> Date = Date.init
    ) {
        self.attemptFree = attemptFree
        self.isActive = isActive
        self.deadline = deadline
        self.waitForTransport = waitForTransport
        self.now = now
    }

    public func run() -> SSHChannelFreeOutcome {
        while true {
            guard case .wouldBlock(let directions) = attemptFree() else { return .freed }
            guard isActive() else { return .stopped }
            guard now() < deadline else { return .timedOut }
            waitForTransport(directions)
        }
    }
}
