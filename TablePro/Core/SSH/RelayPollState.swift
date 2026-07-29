//
//  RelayPollState.swift
//  TablePro
//

import Foundation

internal enum RelayFDState: Equatable {
    case idle
    case readable
    case drainThenStop
    case stop
}

internal func relayFDState(_ revents: Int16) -> RelayFDState {
    if revents & Int16(POLLERR | POLLNVAL) != 0 { return .stop }
    if revents & Int16(POLLHUP) != 0 { return .drainThenStop }
    if revents & Int16(POLLIN) != 0 { return .readable }
    return .idle
}

/// Outcome of waiting for a specific direction on the SSH transport. Distinct from
/// `RelayFDState`, which classifies a read-side poll where "no bits set" means idle.
/// Here "no bits set" means the wait expired without the requested direction becoming
/// ready, which must not be mistaken for readiness.
internal enum TransportPollOutcome: Equatable {
    case ready
    case timedOut
    case hangup
}

internal func transportPollOutcome(revents: Int16, requestedEvents: Int16) -> TransportPollOutcome {
    if revents & Int16(POLLERR | POLLNVAL | POLLHUP) != 0 { return .hangup }
    if revents & requestedEvents != 0 { return .ready }
    return .timedOut
}

/// Waits for libssh2's requested block directions to become ready on the transport.
/// When libssh2 reports no direction, there is nothing to wait on, so this yields
/// briefly instead of returning immediately, which would let a caller retry in a
/// zero-yield spin.
internal func pollReady(fd: Int32, directions: RelayDirections, timeoutMs: Int32) -> Bool {
    var events: Int16 = 0
    if directions.contains(.inbound) { events |= Int16(POLLIN) }
    if directions.contains(.outbound) { events |= Int16(POLLOUT) }

    guard events != 0 else {
        usleep(directionlessYieldMicroseconds)
        return true
    }

    var pollFD = pollfd(fd: fd, events: events, revents: 0)
    return poll(&pollFD, 1, timeoutMs) > 0
}

private let directionlessYieldMicroseconds: UInt32 = 1_000
