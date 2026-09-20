//
//  SSHForwardChannelOpening.swift
//  TableProSSHTransport
//

import Foundation

/// Result of a single non-blocking attempt to open a forwarding channel. A failure carries
/// libssh2's own message because it names the cause the user needs (a refused destination, a
/// forwarding policy on the server) and is otherwise lost by the time anything can report it.
public enum SSHForwardChannelAttempt {
    case opened(OpaquePointer)
    case wouldBlock(RelayDirections)
    case failed(code: Int32, message: String)
}

/// One non-blocking attempt to open a forwarding channel. Implementations must return
/// promptly: the caller drives retries and owns the deadline, so an implementation that
/// blocks would stall every other channel sharing the session.
public protocol SSHForwardChannelOpening {
    func attemptOpen() -> SSHForwardChannelAttempt
}
