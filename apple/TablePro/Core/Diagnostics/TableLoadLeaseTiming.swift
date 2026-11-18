//
//  TableLoadLeaseTiming.swift
//  TablePro
//

import Foundation
import os

// The lease and the pin happen deep in the driver path, so their instants are stamped there and read on the main actor.
internal final class TableLoadLeaseTiming: Sendable {
    internal struct Instants: Equatable, Sendable {
        var leaseAcquired: ContinuousClock.Instant?
        var pinFinished: ContinuousClock.Instant?
        var firstRow: ContinuousClock.Instant?
    }

    @TaskLocal internal static var current: TableLoadLeaseTiming?

    private let state = OSAllocatedUnfairLock(initialState: Instants())

    internal var instants: Instants {
        state.withLock { $0 }
    }

    internal func noteLeaseAcquired(at instant: ContinuousClock.Instant = .now) {
        state.withLock { $0.leaseAcquired = $0.leaseAcquired ?? instant }
    }

    internal func notePinFinished(at instant: ContinuousClock.Instant = .now) {
        state.withLock { $0.pinFinished = $0.pinFinished ?? instant }
    }

    // A pooled lease already sits on its database, so it reaches the body with no pin of its own.
    internal func noteDriverReady(at instant: ContinuousClock.Instant = .now) {
        state.withLock {
            $0.leaseAcquired = $0.leaseAcquired ?? instant
            $0.pinFinished = $0.pinFinished ?? instant
        }
    }

    internal func noteFirstRow(at instant: ContinuousClock.Instant = .now) {
        state.withLock { $0.firstRow = $0.firstRow ?? instant }
    }
}
