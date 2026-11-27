//
//  SSHChannelHandOff.swift
//  TableProSSHTransport
//

import Foundation
import os

// Holds the channel a tunnel opened to check its destination, for the first client the listener accepts. That
// open is the round trip the client's own would have cost, so keeping it saves one channel open per connect.
// Past the window the channel is not handed on: a server that times out a silent handshake (MySQL's
// connect_timeout can be as low as 2 s) may already have closed it, and the client would read an end of stream.
public final class SSHChannelHandOff: @unchecked Sendable {
    public enum Taken: Equatable {
        case fresh(OpaquePointer)
        case stale(OpaquePointer)
        case none
    }

    public static let defaultWindow: Duration = .seconds(1)

    private struct Held: @unchecked Sendable {
        let channel: OpaquePointer
        let openedAt: ContinuousClock.Instant
    }

    private struct Slot: Sendable {
        var held: Held?
        var isClosed = false
    }

    private let window: Duration
    private let slot = OSAllocatedUnfairLock(initialState: Slot())

    public init(window: Duration = SSHChannelHandOff.defaultWindow) {
        self.window = window
    }

    // False once the slot is closed: the tunnel is going away, and the caller still owns the channel.
    public func hold(_ channel: OpaquePointer, openedAt: ContinuousClock.Instant = .now) -> Bool {
        let entry = Held(channel: channel, openedAt: openedAt)
        return slot.withLock { slot -> Bool in
            guard !slot.isClosed else { return false }
            slot.held = entry
            return true
        }
    }

    // Empties the slot, so exactly one caller gets the channel.
    public func take(at now: ContinuousClock.Instant = .now) -> Taken {
        guard let taken = slot.withLock({ slot -> Held? in
            defer { slot.held = nil }
            return slot.held
        }) else { return .none }
        return taken.openedAt.duration(to: now) < window ? .fresh(taken.channel) : .stale(taken.channel)
    }

    // Refuses every later hold and gives back what was held, so a channel the open hands over after teardown
    // began is freed by its opener rather than left in a slot nobody empties.
    public func close() -> OpaquePointer? {
        slot.withLock { slot -> Held? in
            slot.isClosed = true
            defer { slot.held = nil }
            return slot.held
        }?.channel
    }
}
