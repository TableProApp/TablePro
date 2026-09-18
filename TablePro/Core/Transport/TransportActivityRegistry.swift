//
//  TransportActivityRegistry.swift
//  TablePro
//

import Foundation
import os

/// The one place that answers what a connection's transport is carrying.
///
/// A transport is built by its own manager, on its own actor, and the surface that reports it is on
/// the main actor, so asking each manager in turn would mean an actor hop per transport per sample.
/// The registry is a plain lock-guarded table instead, which the readout can read synchronously
/// while it is on screen.
///
/// Entries are held weakly, and the transport itself owns its counter. That is what makes teardown
/// impossible to get wrong: a tunnel that dies, is closed, or is replaced by a reconnect takes its
/// counter with it and the entry becomes absent on its own. An explicit `unregister` would have to
/// be called from every one of those paths, and the one that was missed would report a dead
/// tunnel's totals as the live connection's.
final class TransportActivityRegistry: Sendable {
    static let shared = TransportActivityRegistry()

    private struct Entry {
        weak var counter: TransportByteCounter?
    }

    private let entries = OSAllocatedUnfairLock(initialState: [UUID: Entry]())

    init() {}

    /// Registering is also when the table is swept, so an entry whose transport has gone costs one
    /// dictionary slot until the next transport opens rather than until the app quits.
    func register(_ counter: TransportByteCounter, for connectionId: UUID) {
        entries.withLock { table in
            table = table.filter { $0.value.counter != nil }
            table[connectionId] = Entry(counter: counter)
        }
    }

    func totals(for connectionId: UUID) -> TransportByteTotals? {
        entries.withLock { $0[connectionId]?.counter?.totals }
    }

    var measuredConnectionIds: Set<UUID> {
        entries.withLock { Set($0.filter { $0.value.counter != nil }.keys) }
    }
}
