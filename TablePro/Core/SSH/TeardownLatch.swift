//
//  TeardownLatch.swift
//  TablePro
//

import Foundation
import os

/// Names exactly one owner for a teardown that must happen once.
///
/// A tunnel can stop for two reasons at once: the app closes it, and its keep-alive notices the
/// server has gone. Both need to release the same listening socket, session and jump hops, and
/// neither may do it twice. A bare boolean invites the shape that caused #2474's collateral leak:
/// one path took the flag to mean "someone else will tear down" and returned, the other took it to
/// mean "I have already torn down" and also returned, so nothing was ever released and the tunnel
/// went permanently deaf to close.
///
/// `claim()` returns true to exactly one caller for the lifetime of the latch. **Whoever gets true
/// owes the teardown.** Checking `isLive` never claims.
struct TeardownLatch: Sendable {
    private let live = OSAllocatedUnfairLock(initialState: true)

    /// True for the first caller and false for every caller after it, including concurrent ones.
    func claim() -> Bool {
        live.withLock { isLive -> Bool in
            let was = isLive
            isLive = false
            return was
        }
    }

    /// Whether the thing this latch guards is still running. Observation only; never claims.
    var isLive: Bool {
        live.withLock { $0 }
    }
}
