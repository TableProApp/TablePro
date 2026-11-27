//
//  RelayPollState.swift
//  TableProSSHTransport
//

import Foundation

// Waits for libssh2's requested block directions to become ready on the transport.
// When libssh2 reports no direction, there is nothing to wait on, so this yields
// briefly instead of returning immediately, which would let a caller retry in a
// zero-yield spin.
public func pollReady(fd: Int32, directions: RelayDirections, timeoutMs: Int32) -> Bool {
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

public enum TransportRoom: Equatable, Sendable {
    case room
    case full
    case gone
}

// A socket polls writable once its send low-water mark is free (2048 bytes unless set), which holds a small
// packet whole. A reset or closed socket reports a hangup or an error instead.
public func transportRoom(_ descriptor: Int32) -> TransportRoom {
    var pollFD = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    guard poll(&pollFD, 1, 0) == 1 else { return .full }
    if pollFD.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return .gone }
    return pollFD.revents & Int16(POLLOUT) != 0 ? .room : .full
}
