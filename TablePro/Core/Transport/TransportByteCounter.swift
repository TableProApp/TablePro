//
//  TransportByteCounter.swift
//  TablePro
//

import Foundation
import os

/// Bytes a connection's transport has carried since it was opened, in each direction.
///
/// Totals rather than a rate, because a total is the only figure that stays true whatever the
/// sampling interval is. The rate is derived from two of these by `TransportRateSampler`, which
/// divides by the interval it actually measured rather than by the one it asked for.
struct TransportByteTotals: Equatable, Sendable {
    var received: UInt64
    var sent: UInt64

    static let zero = TransportByteTotals(received: 0, sent: 0)
}

/// Accumulates the bytes crossing one connection's transport.
///
/// A tunnel serves every client socket the driver opens, each on its own task of a concurrent
/// queue, so the counter is shared and has to be safe against concurrent increments. The lock is
/// the same primitive `LibSSH2Tunnel` already holds its client tasks behind, and the increment is
/// the whole cost: the byte count is already a plain `Int` in the caller's hand the instant the
/// read returns, so nothing here reads the clock or makes a syscall.
final class TransportByteCounter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: TransportByteTotals.zero)

    init() {}

    var totals: TransportByteTotals {
        state.withLock { $0 }
    }

    func recordReceived(_ count: Int) {
        guard count > 0 else { return }
        state.withLock { $0.received &+= UInt64(count) }
    }

    func recordSent(_ count: Int) {
        guard count > 0 else { return }
        state.withLock { $0.sent &+= UInt64(count) }
    }
}
